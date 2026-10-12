// TaxTriageRunTextOutputTests.swift - What `taxtriage run` prints, as a person at a terminal reads it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane U9, row U9 of the UX inventory and note 8 of the 2.8 U2 review. `taxtriage run`
// prints text only. A progress line rewrites itself with a carriage return, `[pct%] message`, and the
// run closes with `TaxTriage completed in <t>s` or, when Nextflow ignored errored tasks,
// `TaxTriage completed with warnings in <t>s`. Neither line had a test.
//
// Each case runs the command in this process with the pipeline factory bound to
// `TaxTriageStandInEngine`, as the SIGTERM and parity replay classes do, and reads standard output
// and standard error from files that stand in for them. The cases pinned today's words at the base.
// They pin the last progress line and the closing line only. The lines in between carry the engine's
// own text, which a later words lane changes, and this class leaves them alone. Lane A2 runs the
// command on the executor, which moved the end of the bar from 100 to 90 percent (W3) and the warning
// paragraph to standard error (UX D11), and the landing of A2 and U10 changed the two expectations.
//
// The stand-in starts a shell script as the managed Nextflow, never the real tool, so the class
// needs no Docker and runs in the unit tier.

import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageRunTextOutputTests: XCTestCase {
    /// What one run printed, split the way a terminal shows it.
    private struct PrintedRun {
        let text: String

        /// What the command wrote to standard error. Since lane A2 runs `taxtriage run` on the executor, its failures
        /// and warnings go there (UX D11).
        let errorText: String

        /// Every `[pct%] message` the command printed, in order. They share one physical line,
        /// each begun by a carriage return and ended by two spaces.
        var progressLines: [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.contains("\r") }
                .flatMap { $0.split(separator: "\r").map(String.init) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("[") && $0.contains("%]") }
        }

        /// The lines a terminal shows after the progress line, without the empty ones.
        var linesAfterProgress: [String] {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let last = lines.lastIndex(where: { $0.contains("\r") }) else { return [] }
            return lines[(last + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        /// The last line of the output, the one a script would read as the verdict.
        var closingLine: String? { linesAfterProgress.last }
    }

    // MARK: - A clean run

    /// A run that ignores nothing ends its progress on 90 percent with the pipeline's closing
    /// message and closes with the plain completed line. The executor keeps the last tenth of the bar
    /// for the finalize that indexes a result (A2 M3, W3), and a plain `--output` run has none.
    func testACleanRunEndsItsProgressOnTheCompleteMessageAndClosesWithTheCompletedLine() async throws {
        let printed = try await printedRun(.completes)

        XCTAssertEqual(printed.progressLines.last, "\u{2139} [90%] TaxTriage pipeline complete", "\(printed.progressLines)")
        XCTAssertEqual(
            Self.maskingRuntime(printed.closingLine),
            "\u{2713} TaxTriage completed in <seconds>s",
            "\(printed.linesAfterProgress)"
        )
        XCTAssertFalse(printed.text.contains("completed with warnings"), "a clean run prints no warnings line")
    }

    // MARK: - A run that ignored errored tasks

    /// Nextflow exits 0 when TaxTriage ignores an errored task. The command prints the warning
    /// paragraph, the same text the app logs as the row's warning line, on standard error (UX D11, A2),
    /// and closes with the warnings form of the completed line (2.8 U2 fix 2). The progress ends on 90
    /// percent as in the clean run.
    func testARunThatIgnoredErroredTasksPrintsTheParagraphAndClosesWithTheWarningsLine() async throws {
        let printed = try await printedRun(.reportsErroredTasks)

        XCTAssertEqual(printed.progressLines.last, "\u{2139} [90%] TaxTriage pipeline complete", "\(printed.progressLines)")
        let headline = "Some TaxTriage tasks failed: MINIMAP2_ALIGN failed for S1 (killed, usually for running out of memory)"
        let paragraph = "\(headline). Results that depend on the failed steps, such as alignments and TASS scores, are missing for the samples named."
            + " Raise Max memory, or list the host in Exclude host taxa (9606 for human) so the host genome is not downloaded as an alignment reference."
        let after = printed.linesAfterProgress
        XCTAssertTrue(
            printed.errorText.split(separator: "\n").map(String.init).contains("\u{26A0} \(paragraph)"),
            "standard error: \(printed.errorText)"
        )
        XCTAssertEqual(
            Self.maskingRuntime(printed.closingLine),
            "\u{26A0} TaxTriage completed with warnings in <seconds>s",
            "\(after)"
        )
        XCTAssertFalse(printed.text.contains("\u{2713} TaxTriage completed in"), "a run with warnings prints no plain completed line")
    }

    // MARK: - Running the command

    /// Runs `taxtriage run` on the stand-in engine for one sample and returns what it printed.
    private func printedRun(_ behaviour: TaxTriageStandInEngine.Behaviour) async throws -> PrintedRun {
        let folder = try TestTempDirectory.make(prefix: "taxtriage-run-text")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        let engine = try TaxTriageStandInEngine(
            root: folder.appendingPathComponent("engine", isDirectory: true),
            behaviour: behaviour
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        let reads = folder.appendingPathComponent("S1.fastq")
        let records = (1...3).map { "@S1-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try records.write(to: reads, atomically: true, encoding: .utf8)
        let database = folder.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let command = try TaxTriageCommand.RunSubcommand.parse([
            "run",
            "--input", reads.path,
            "--sample", "S1",
            "--output", folder.appendingPathComponent("output", isDirectory: true).path,
            "--db", database.path,
            "--nf-profile", TaxTriageStandInEngine.profile,
            "--max-cpus", "2",
            "--no-color",
        ])

        let captured = folder.appendingPathComponent("stdout.txt")
        let capturedErrors = folder.appendingPathComponent("stderr.txt")
        try await Self.capture(STDERR_FILENO, to: capturedErrors) {
            try await Self.capture(STDOUT_FILENO, to: captured) {
                try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
                    try await command.run()
                }
            }
        }
        return PrintedRun(
            text: try String(contentsOf: captured, encoding: .utf8),
            errorText: try String(contentsOf: capturedErrors, encoding: .utf8)
        )
    }

    /// Runs `operation` with the stream `descriptor` (standard output or standard error) pointed at
    /// `file`, and puts it back afterwards. The file never fills a pipe, so a long run cannot block on it.
    private static func capture(_ descriptor: Int32, to file: URL, _ operation: () async throws -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        fflush(nil)
        let saved = dup(descriptor)
        dup2(handle.fileDescriptor, descriptor)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(nil)
        dup2(saved, descriptor)
        close(saved)
        try? handle.close()
        if let thrown { throw thrown }
    }

    private static func maskingRuntime(_ line: String?) -> String? {
        line?.replacingOccurrences(of: #"[0-9]+\.[0-9]s"#, with: "<seconds>s", options: .regularExpression)
    }
}
