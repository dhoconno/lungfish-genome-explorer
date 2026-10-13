// KrakenCompactionFailureTests.swift - A compaction that cannot remove the per-read output keeps what its steps name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, row 268 of docs/plans/2026-10-11-phase-2-8.md and ARCH 5, cleanup deletes nothing a record
// names. The index step and the gzip step record their outputs before the pipeline removes `classification.kraken`.
// When that removal throws, the compaction's `catch` deleted the gzip copy and the index its own steps name, with no
// step to say so. The stand-in kraken2 makes its per-read output immutable (`chflags uchg`), which stops the removal
// and nothing else, because the index and the gzip copy only read the file.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenCompactionFailureTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-compaction-failure")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The removal of the raw output throws. The run still completes with the raw output as its result, the gzip
    /// copy and the index its steps name stay where the steps name them, and no step names a file that is gone.
    func testAFailedRemovalOfThePerReadOutputKeepsTheCopiesItsStepsName() async throws {
        let kraken2 = try LockingKraken2(root: root.appendingPathComponent("stand-in"))
        let reads = root.appendingPathComponent("reads.fastq")
        try ReadSetFixtures.fastq(["s1", "s2"]).write(to: reads, atomically: true, encoding: .utf8)
        let config = ClassificationConfig(
            inputFiles: [reads],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            databasePath: kraken2.databaseURL,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true)
        )
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: config.outputURL.path) }

        let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)

        let compressed = config.outputURL.appendingPathExtension("gz")
        let index = KrakenIndexDatabase.indexURL(for: compressed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.outputURL.path), "the removal failed, so the raw output stays")
        XCTAssertEqual(result.outputURL.standardizedFileURL, config.outputURL.standardizedFileURL, "and it stays the result's output")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(KrakenRecordRemoval.problems(in: envelope), [], "no step names a file that is gone")
        let gzip = try KrakenRecordRemoval.step("gzip", in: envelope)
        let indexStep = try KrakenRecordRemoval.step("lungfish-kraken2-index", in: envelope)
        XCTAssertEqual(gzip.outputs.map(\.path), [compressed.path])
        XCTAssertEqual(indexStep.outputs.map(\.path), [index.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path), "the gzip copy stays beside the raw output")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path), "the index stays beside it")
        XCTAssertFalse(
            envelope.steps.contains { $0.toolName == ClassificationPipeline.kraken2OutputRemovalToolName },
            "nothing was removed, so no removal step"
        )
    }
}

/// A conda root whose stand-in micromamba runs a stand-in kraken2 that writes one report and one per-read line,
/// then makes the per-read output immutable.
private struct LockingKraken2 {
    let condaManager: CondaManager
    let databaseURL: URL

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: databaseURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script.write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    private static let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
        [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
        shift
        if [ "$1" = "-n" ]; then shift; shift; fi
        tool="$1"; shift
        [ "$tool" = "kraken2" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
        if [ "$1" = "--version" ]; then echo "Kraken version 2.1.3"; exit 0; fi
        report=""; output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --report) shift; report="$1" ;;
            --output) shift; output="$1" ;;
          esac
          shift
        done
        mkdir -p "$(dirname "$report")" "$(dirname "$output")"
        printf '100.00\\t1\\t0\\tR\\t1\\troot\\n100.00\\t1\\t1\\tS\\t562\\t  Escherichia coli\\n' > "$report"
        printf 'C\\tread1\\t562\\t4\\t0:4\\nC\\tread2\\t562\\t4\\t0:4\\n' > "$output"
        chflags uchg "$output" || exit 70
        echo "2 sequences (0.00 Mbp) processed in 0.001s (1.0 Kseq/m, 0.01 Mbp/m)." >&2
        exit 0
        """
}
