// CLIImportRunnerTranscriptTests.swift - What the Operations row shows for real runs of `import fastq`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Combine
import XCTest
import Darwin
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishApp

/// Lane Q4 of Phase 2.7 (scope row B8, the `import fastq` stream S1). A stand-in `lungfish-cli` prints
/// what a real run of the built CLI printed, from `Tests/Fixtures/cli-events/import-fastq-runs`, and
/// `CLIImportRunner` reads it as the Import FASTQ sheet's run does. The test then ends the row as
/// `FASTQIngestionService.runIngestAndBundle` ends it and records what the row holds: each log line
/// with its level, each progress fraction with its detail, the label, the bundle the caller is
/// handed and what `onError` heard. Durations change from run to run, so they read `<t>`.
///
/// `s1-runner.json` holds what the runner of the base `247504866` showed for the three runs of the
/// S1 stream that the base CLI printed: a VSP2 import given `--platform element` for reads named
/// as Illumina reads, which logs one notice and one read delta, a single-end file the recipe
/// refuses, and the first run again cancelled once its first step began. The file is frozen, and
/// the same three runs of the version 2 stream, from the CLI that retired S1, are compared with it.
final class CLIImportRunnerTranscriptTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await OperationCenter.useTemporaryFailureReportsForTesting()
    }

    /// One real run, as the stand-in prints it.
    struct RecordedRun {
        /// `complete-with-warning`, `failed` or `cancelled`.
        let name: String
        /// The file names of its standard output and standard error in the runs folder.
        let standardOutput: String
        let standardError: String
        /// The status the real run exited with.
        let status: Int32
        /// Whether the row is cancelled once every line was printed, as the real run was.
        let cancels: Bool
    }

    /// What the row showed for one run.
    struct Observation: Codable, Equatable {
        var log: [String]
        var progress: [String]
        var label: String
        var bundles: [String]
        var errors: [String]
        var errorMessage: String?
        var errorDetail: String?
    }

    static let s1Runs = [
        RecordedRun(name: "complete-with-warning", standardOutput: "s1-complete-with-warning.stdout",
                    standardError: "s1-complete-with-warning.stderr", status: 0, cancels: false),
        RecordedRun(name: "failed", standardOutput: "s1-failed.stdout", standardError: "s1-failed.stderr",
                    status: 64, cancels: false),
        RecordedRun(name: "cancelled", standardOutput: "s1-cancelled.stdout", standardError: "s1-cancelled.stderr",
                    status: 125, cancels: true),
    ]

    static let v2Runs = [
        RecordedRun(name: "complete-with-warning", standardOutput: "../commands/import-fastq/complete-with-warning.ndjson",
                    standardError: "v2-complete-with-warning.stderr", status: 0, cancels: false),
        RecordedRun(name: "failed", standardOutput: "../commands/import-fastq/failed.ndjson",
                    standardError: "v2-failed.stderr", status: 64, cancels: false),
        RecordedRun(name: "cancelled", standardOutput: "../commands/import-fastq/failed-cancelled.ndjson",
                    standardError: "v2-failed-cancelled.stderr", status: 125, cancels: true),
    ]

    static var runsFolder: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/cli-events/import-fastq-runs", isDirectory: true)
    }

    // MARK: The version 2 runs against the base

    /// Each real run of the version 2 stream reads in the row as the same run of the S1 stream read at
    /// the base, `s1-runner.json`, apart from four deliberate differences named below.
    func testEachRealVersion2RunReadsInTheRowAsItsS1RunDidAtTheBase() async throws {
        let base = try JSONDecoder().decode(
            [String: Observation].self, from: Data(contentsOf: Self.runsFolder.appendingPathComponent("s1-runner.json"))
        )
        for run in Self.v2Runs {
            let observed = try await observe(run)
            var expected = try XCTUnwrap(base[run.name])

            // 1. One fraction for the whole import that only moves forward (UX objection 4), so the
            //    bar no longer falls back from the launch fraction when a sample starts.
            var floor = 0.0
            expected.progress = expected.progress.map { state in
                floor = max(floor, Double(state.prefix(5)) ?? 0)
                return String(format: "%.3f", floor) + state.dropFirst(5)
            }
            // 2. onError hears a failure once, from the failed line, where S1 also reported the sample,
            //    and a cancel as a cancel, where S1 read the exit status of the signal.
            switch run.name {
            case "failed": expected.errors = Array(expected.errors.suffix(1))
            case "cancelled": expected.errors = ["Import cancelled"]
            default: break
            }
            // 3. A failed line with one failure carries no detail, so the row's error detail and its
            //    last log line, the exit status, are gone.
            if run.name == "failed" {
                expected.errorDetail = nil
                expected.log.removeAll { $0 == "error: CLI exited with status 64" }
            }
            // 4. The human text on standard error reaches the log at info through the transport, and
            //    the platform each sample is imported as is logged at info. Neither changes the label.
            let humanText = Set(try String(contentsOf: Self.runsFolder.appendingPathComponent(run.standardError), encoding: .utf8)
                .split(separator: "\n").map { "info: " + Self.withoutDurations(String($0)) })
            let added = observed.log.filter { humanText.contains($0) || ($0.hasPrefix("info: ") && $0.contains(": Platform: ")) }
            XCTAssertTrue(added.allSatisfy { $0.hasPrefix("info: ") }, "\(run.name) adds only info lines: \(added)")
            XCTAssertTrue(added.contains { $0.contains(": Platform: ") }, "\(run.name) logs the platform")
            var shown = observed
            shown.log.removeAll { added.contains($0) }

            XCTAssertEqual(shown, expected, "The row of the \(run.name) run")
        }
    }

    /// Plan decision T5. An older `lungfish-cli`, which prints the S1 stream of these runs, ends with a
    /// failed row whose message names the mismatch, and no bundle is handed over.
    func testAnOlderCLIThatPrintsS1EndsWithAMessageThatNamesTheMismatch() async throws {
        for run in Self.s1Runs where !run.cancels {
            let observed = try await observe(run)

            XCTAssertEqual(observed.label, "Failed", run.name)
            XCTAssertEqual(observed.bundles, [], run.name)
            let message = try XCTUnwrap(observed.errorMessage, run.name)
            XCTAssertTrue(message.hasPrefix("This copy of lungfish-cli at /"), message)
            XCTAssertTrue(message.contains("/lungfish-cli is older than the app and cannot report import progress."), message)
            XCTAssertTrue(message.hasSuffix(" Reinstall Lungfish Genome Explorer."), message)
            XCTAssertEqual(observed.errors, [message], run.name)
        }
    }

    // MARK: Playing a run

    /// Plays `run` through `CLIImportRunner` and ends the row as the Import FASTQ sheet's caller does.
    func observe(_ run: RecordedRun) async throws -> Observation {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-import-transcript-\(UUID().uuidString)", isDirectory: true)
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A real run names the project `/work/Project.lungfish`, and the stand-in names this one.
        func copy(_ name: String, to destination: URL) throws {
            let text = try String(contentsOf: Self.runsFolder.appendingPathComponent(name), encoding: .utf8)
                .replacingOccurrences(of: "\\/work\\/Project.lungfish", with: project.path.replacingOccurrences(of: "/", with: "\\/"))
                .replacingOccurrences(of: "/work/Project.lungfish", with: project.path)
            try text.write(to: destination, atomically: true, encoding: .utf8)
        }
        let standardOutput = folder.appendingPathComponent("stdout.txt")
        let standardError = folder.appendingPathComponent("stderr.txt")
        try copy(run.standardOutput, to: standardOutput)
        try copy(run.standardError, to: standardError)
        let printed = folder.appendingPathComponent("printed")
        let script = run.cancels
            ? """
            #!/bin/sh
            trap 'exit \(run.status)' TERM
            cat '\(standardOutput.path)'
            cat '\(standardError.path)' >&2
            # The shell's own note on the signal that ends its sleep is not the run's text.
            exec 2>/dev/null
            touch '\(printed.path)'
            while true; do sleep 0.1; done
            """
            : """
            #!/bin/sh
            cat '\(standardOutput.path)'
            cat '\(standardError.path)' >&2
            exit \(run.status)
            """
        let cli = folder.appendingPathComponent("lungfish-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        defer {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }

        let row = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: \(run.name)", detail: "Starting", operationType: .ingestion, cliCommand: nil
            ).rowID
        }
        let watcher = await MainActor.run { ImportRowWatcher(row: row) }
        let bundles = ImportTranscriptCollector<URL>()
        let errors = ImportTranscriptCollector<String>()
        let runner = CLIImportRunner()
        let task = Task {
            await runner.run(
                arguments: [], operationID: row, projectDirectory: project,
                onBundleCreated: { bundles.append($0) }, onError: { errors.append($0) }
            )
        }
        if run.cancels {
            let finishedPrinting = await waitUntil(timeout: .seconds(30)) {
                FileManager.default.fileExists(atPath: printed.path)
            }
            XCTAssertTrue(finishedPrinting, "the stand-in printed the \(run.name) run")
            task.cancel()
        }
        await task.value

        return await MainActor.run {
            // As FASTQIngestionService.runIngestAndBundle ends the row.
            if run.cancels {
                OperationCenter.shared.acknowledgeCancellation(id: row)
            } else if let bundle = bundles.values.last {
                _ = OperationCenter.shared.complete(id: row, detail: "Imported \(bundle.lastPathComponent)", bundleURLs: [bundle])
            } else {
                _ = OperationCenter.shared.fail(id: row, detail: errors.values.last ?? "Import produced no output bundle")
            }
            let item = OperationCenter.shared.items.first { $0.id == row }
            let observation = Observation(
                log: item?.logEntries.map { "\($0.level): \(Self.withoutDurations($0.message))" } ?? [],
                progress: watcher.states,
                label: item?.displayStateLabel ?? "no row",
                bundles: bundles.values.map { String($0.path.dropFirst(project.path.count + 1)) },
                errors: errors.values,
                errorMessage: item?.errorMessage,
                errorDetail: item?.errorDetail.map(Self.withoutDurations)
            )
            watcher.stop()
            OperationCenter.shared.clearItem(id: row)
            return observation
        }
    }

    /// A duration such as `(7.7s)` or `(0s)` reads `(<t>s)`.
    static func withoutDurations(_ text: String) -> String {
        text.replacingOccurrences(of: #"\(\d+(\.\d+)?s\)"#, with: "(<t>s)", options: .regularExpression)
    }
}

/// The progress fraction and detail of one row, each time either changes.
@MainActor
private final class ImportRowWatcher {
    private var subscription: AnyCancellable?
    private(set) var states: [String] = []

    init(row: UUID) {
        record(row)
        subscription = OperationCenter.shared.changes.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.record(row) }
        }
    }

    func stop() {
        subscription = nil
    }

    private func record(_ row: UUID) {
        guard let item = OperationCenter.shared.items.first(where: { $0.id == row }) else { return }
        let state = String(format: "%.3f ", item.progress) + item.detail
        if states.last != state { states.append(state) }
    }
}

private final class ImportTranscriptCollector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}
