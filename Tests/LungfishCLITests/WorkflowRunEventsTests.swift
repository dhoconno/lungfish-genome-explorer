// WorkflowRunEventsTests.swift - workflow run prints only CLIEvent lines under --format json, on both routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, ARCH's ruling on M3 (commit 5). `workflow run` is an events leaf. Under --format json its
// standard output holds only `CLIEvent` lines: an empty `start`, the lines text mode prints as info events, the Docker
// wait's two lines as progress at 0.01 and 0.02, the outcome lines as warning log events, and `complete` with the run
// bundle and the results folder, or `failed`. The empty `start` leaves a row's first detail alone, and the words
// `Preparing workflow` come as the first info event (A30 M3 review, fix 3). The missing annotation notice is an info
// event with its words unchanged. Each case runs the command in this process on the stand-in runners of
// WorkflowRunCapture.swift.
//
// The three Viral Recon cases are the transcripts of the leaf, `Tests/Fixtures/cli-events/commands/workflow-run`, with
// the case's folder written as `/work`. A case fails when its lines differ from its transcript, and
// `LUNGFISH_RECAPTURE_CLI_EVENTS=1` writes them instead, for review in the diff.

import ArgumentParser
import Foundation
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class WorkflowRunEventsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The CLI standardizes every path it records (/var -> /private/var).
        root = try TestTempDirectory.make(prefix: "workflow-run-events").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var results: URL { root.appendingPathComponent("results", isDirectory: true) }
    private var bundle: URL { root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true) }

    func testACompletedViralReconRunPrintsOnlyEventsEndingInCompleteWithTheBundleAndResults() async throws {
        let run = try await viralRecon(ViralReconStandInRunner(results: results, called: ["S1", "S2"]))

        XCTAssertNil(run.captured.error)
        XCTAssertEqual(run.events.first, .start(message: ""), "a start with words would replace the row's first detail for the whole run")
        XCTAssertEqual(run.events.dropFirst().first, .log(level: .info, message: "Preparing workflow: nf-core/viralrecon"))
        XCTAssertTrue(run.events.contains(.progress(fraction: 0.01, message: "Docker daemon unavailable. Launching Docker Desktop...")))
        XCTAssertTrue(run.events.contains(.progress(fraction: 0.02, message: "Docker daemon ready")))
        XCTAssertTrue(run.events.contains(.log(level: .info, message: "Created run bundle: \(bundle.path)")))
        XCTAssertFalse(run.events.contains { if case .log(.warning, _) = $0 { return true } else { return false } })
        XCTAssertEqual(run.events.last, .complete(outputs: [bundle.path, results.path], message: nil))
        XCTAssertEqual(run.events.filter { if case .start = $0 { return true } else { return false } }.count, 1)
        try assertTranscript("complete", run.lines)
    }

    func testAFailedSampleAndAnIgnoredTaskAreWarningLogEventsAndStayOffStandardError() async throws {
        let trace = "task_id\thash\tname\tstatus\texit\n"
            + "1\taa/000001\tNFCORE_VIRALRECON:VIRALRECON:CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S1)\tFAILED\t1\n"
        let run = try await viralRecon(ViralReconStandInRunner(results: results, called: ["S1"], trace: trace))

        XCTAssertNil(run.captured.error)
        let warnings = run.events.compactMap { event -> String? in
            if case .log(.warning, let message) = event { return message }
            return nil
        }
        XCTAssertEqual(warnings, [
            "Some Viral Recon tasks failed: PANGOLIN_RUN (S1). Their outputs are missing.",
            "1 failed sample: S2. Too few reads were left after trimming or mapping to call variants.",
        ])
        XCTAssertFalse(run.captured.standardError.contains("failed"), "an outcome reaches a reader once: \(run.captured.standardError)")
        XCTAssertEqual(run.events.last, .complete(outputs: [bundle.path, results.path], message: nil))
        try assertTranscript("complete-with-warning", run.lines)
    }

    func testAFailedEngineEndsInFailed() async throws {
        let run = try await viralRecon(ViralReconStandInRunner(
            results: results, called: [], exitCode: 1, standardError: "ERROR ~ Error executing process > 'FASTP (S1)'\n"
        ))

        let error = try XCTUnwrap(run.captured.error, "a failed engine fails the command")
        XCTAssertEqual(run.events.last, .failed(message: WorkflowRunOutput.message(for: error), detail: nil))
        XCTAssertFalse(run.events.contains { if case .complete = $0 { return true } else { return false } })
        try assertTranscript("failed", run.lines)
    }

    func testALocalWorkflowRunPrintsOnlyEventsToo() async throws {
        let workflow = root.appendingPathComponent("main.nf")
        try "workflow {\n}\n".write(to: workflow, atomically: true, encoding: .utf8)
        let localBundle = root.appendingPathComponent("local.lungfishrun", isDirectory: true)
        let arguments = [
            workflow.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", localBundle.path,
            "--format", "json",
        ]
        let captured = try await WorkflowRunCapture.run(in: root) {
            try await RunSubcommand.parse(arguments).run(localRunner: LocalWorkflowStandInRunner(results: self.results))
        }

        XCTAssertNil(captured.error)
        let events = try Self.decode(Self.lines(of: captured.standardOutput))
        XCTAssertEqual(events.first, .start(message: ""))
        XCTAssertEqual(events.dropFirst().first, .log(level: .info, message: "Preparing workflow: \(workflow.path)"))
        XCTAssertTrue(events.contains(.log(level: .info, message: "Detected workflow engine: Nextflow")))
        XCTAssertEqual(events.last, .complete(outputs: [localBundle.path, results.path], message: nil))
    }

    /// The missing annotation notice states a fact about the input before the launch, not the run's outcome, so under
    /// --format json it is an info event with its words unchanged, and text mode keeps its warning form on standard
    /// output (BIO's and UX's view in the ruling).
    func testTheMissingAnnotationNoticeIsAnInfoEventWithItsWordsUnchanged() throws {
        let notice = "The reference bundle R.lungfishref has no annotation, so viralrecon runs without --gff. "
            + "iVar merges no codons, and SnpEff and the variants long table are skipped."
        let sink = LineSink()
        WorkflowRunOutput(formatter: TerminalFormatter(useColors: false), quiet: false, eventsOn: true, emit: { sink.append($0) })
            .notice(notice)
        XCTAssertEqual(try Self.decode(sink.lines), [.log(level: .info, message: notice)])

        let text = try WorkflowRunCaptureSync.standardOutput(in: root) {
            WorkflowRunOutput(formatter: TerminalFormatter(useColors: false), quiet: false, eventsOn: false).notice(notice)
        }
        XCTAssertEqual(text, "⚠ \(notice)\n")
    }

    // MARK: - Helpers

    /// The event lines one output wrote, kept under a lock.
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func append(_ line: String) {
            lock.withLock { stored.append(line) }
        }

        var lines: [String] {
            lock.withLock { stored }
        }
    }

    private struct Run {
        let captured: WorkflowRunCapture.Captured
        let lines: [String]
        let events: [CLIEvent]
    }

    /// Runs `workflow run nf-core/viralrecon --format json` on `runner` and decodes every line of standard output,
    /// failing on a line that is not an event.
    private func viralRecon(_ runner: ViralReconStandInRunner) async throws -> Run {
        let arguments = try WorkflowRunCapture.viralReconArguments(root: root) + ["--format", "json"]
        let captured = try await WorkflowRunCapture.run(in: root) {
            try await RunSubcommand.parse(arguments).run(nfCoreRunner: runner)
        }
        let lines = Self.lines(of: captured.standardOutput)
        return Run(captured: captured, lines: lines, events: try Self.decode(lines))
    }

    /// `line` with each path through the run's scratch, a folder `nfcore-run-<UUID>` made anew for every run, written as
    /// `scratch`, in the slash-escaped spelling a JSON line uses. The launch line a run prints names it twice.
    private static func scratchWritten(as scratch: String, in line: String) -> String {
        guard let path = try? NSRegularExpression(pattern: #"[^ "]*nfcore-run-[0-9A-Fa-f-]{36}"#) else { return line }
        let escaped = scratch.replacingOccurrences(of: "/", with: "\\/")
        return path.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line),
            withTemplate: NSRegularExpression.escapedTemplate(for: escaped))
    }

    private static func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func decode(_ lines: [String]) throws -> [CLIEvent] {
        try lines.map { try XCTUnwrap(try CLIEventLineDecoder().decode(line: $0), "standard output holds a line that is not an event: \($0)") }
    }

    /// Compares `lines`, the case's folder written as `/work`, with the leaf's transcript `name`, or writes them there
    /// when `LUNGFISH_RECAPTURE_CLI_EVENTS=1`.
    private func assertTranscript(_ name: String, _ lines: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let escapedRoot = root.path.replacingOccurrences(of: "/", with: "\\/")
        let normalized = lines.map {
            Self.scratchWritten(as: "/scratch", in: $0.replacingOccurrences(of: escapedRoot, with: "\\/work").replacingOccurrences(of: root.path, with: "/work"))
        }
        let url = CLIEventTranscriptCoverageTests.transcriptURL(leaf: "workflow run", name: name)
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (normalized.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(
            normalized,
            expected,
            "workflow run no longer prints its \(name) transcript. If the change is deliberate, run with LUNGFISH_RECAPTURE_CLI_EVENTS=1 and review the diff",
            file: file,
            line: line
        )
    }
}
