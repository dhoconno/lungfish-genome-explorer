// ClassificationCommandParityTests.swift - Copy Classification Command copies each step's recorded argv
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `ClassificationResult.copyableCommandString(from:)` builds the sidebar's Copy
// Classification Command text from the steps of `ProvenanceRecorder.load(from:)`.
// Today that run is the one a classification record embeds under `legacyWorkflowRun`.
// Phase 2.4 stops writing that block (finding R8, lane W1C), and the reader then
// rebuilds the run from the envelope's own steps. This test asserts what the sidebar
// copies, which is the recorded argv of each step, and not whether the writer embeds
// the run, so it holds on both sides of that change.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ClassificationCommandParityTests: XCTestCase {

    func testCopiedClassificationCommandIsTheRecordedArgvOfEachStep() async throws {
        let fixture = try FakeKraken2Fixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()

        // A record written by today's pipeline, as any classification result holds.
        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)
        let directory = config.outputDirectory

        let written = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: directory))
        XCTAssertGreaterThan(written.steps.count, 1, "A realistic record has more than one step.")
        let copiedText = try XCTUnwrap(ClassificationResult.copyableCommandString(from: directory))
        XCTAssertTrue(copiedText.contains("kraken2"), "The text must name the classifier, so equality is not vacuous.")
        XCTAssertTrue(copiedText.contains(config.reportURL.path))

        // The run the sidebar copies from has each step's recorded argv as its command,
        // whether the file stores that run or the reader rebuilds it from the steps, and
        // the copied text holds one command per step.
        let copiedRun = try XCTUnwrap(ProvenanceRecorder.load(from: directory))
        XCTAssertEqual(copiedRun.steps.map(\.command), written.steps.map(\.argv))
        XCTAssertEqual(copiedText.components(separatedBy: "\n\n").count, written.steps.count)
    }
}

// MARK: - Fixture

/// A Kraken2 that a shell script stands in for, run by the real pipeline so the
/// record is the one today's writer produces. It follows the fake used by
/// ClassificationPipelineProvenanceSourceTests, reduced to the classify path.
private struct FakeKraken2Fixture {
    let root: URL
    let condaManager: CondaManager

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "classification-command-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let micromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.script.write(to: micromamba, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeConfig() throws -> ClassificationConfig {
        let database = root.appendingPathComponent("kraken-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        for name in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: database.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let reads = root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        return ClassificationConfig(
            inputFiles: [reads],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databaseVersion: "fixture-v1",
            databasePath: database,
            databaseDigest: "sha256:fixture-db",
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
    }

    /// Answers `micromamba --version`, then `micromamba run -n <env> kraken2 ...`.
    private static let script = #"""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "micromamba 2.0.0"
      exit 0
    fi
    if [ "$1" != "run" ]; then
      echo "unexpected micromamba invocation: $*" >&2
      exit 64
    fi
    shift
    if [ "$1" = "-n" ]; then
      shift
      shift
    fi
    tool="$1"
    shift
    if [ "$tool" != "kraken2" ]; then
      echo "unexpected tool: $tool" >&2
      exit 64
    fi
    if [ "$1" = "--version" ]; then
      echo "Kraken version 2.1.3"
      exit 0
    fi
    report=""
    output=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --report)
          shift
          report="$1"
          ;;
        --output)
          shift
          output="$1"
          ;;
      esac
      shift
    done
    mkdir -p "$(dirname "$report")" "$(dirname "$output")"
    printf '100.00\t1\t0\tR\t1\troot\n100.00\t1\t1\tS\t562\t  Escherichia coli\n' > "$report"
    printf 'C\tread1\t562\t4\t0:4\n' > "$output"
    echo "processed 1 sequence" >&2
    exit 0
    """#
}
