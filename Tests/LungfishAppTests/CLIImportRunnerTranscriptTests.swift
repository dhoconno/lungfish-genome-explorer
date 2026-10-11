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
/// refuses, and the first run again cancelled once its first step began. Set
/// `LUNGFISH_RECAPTURE_IMPORT_RUNNER=1` to write that file instead of comparing with it.
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

    static var runsFolder: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/cli-events/import-fastq-runs", isDirectory: true)
    }

    // MARK: The base

    func testEachRealS1RunReadsInTheRowAsAtTheBase() async throws {
        var observed: [String: Observation] = [:]
        for run in Self.s1Runs {
            observed[run.name] = try await observe(run)
        }
        let recorded = Self.runsFolder.appendingPathComponent("s1-runner.json")
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_IMPORT_RUNNER"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(observed).write(to: recorded)
            return
        }
        let expected = try JSONDecoder().decode([String: Observation].self, from: Data(contentsOf: recorded))
        XCTAssertEqual(Set(observed.keys), Set(expected.keys))
        for run in Self.s1Runs {
            XCTAssertEqual(observed[run.name], expected[run.name], "The row of the \(run.name) run")
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
