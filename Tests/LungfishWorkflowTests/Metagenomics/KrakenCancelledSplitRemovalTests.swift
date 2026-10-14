// KrakenCancelledSplitRemovalTests.swift - A cancelled kraken2 leaves the removal of the halves after its own step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, review fix 4, row 268 of docs/plans/2026-10-11-phase-2-8.md. Fix 4 of the BIO review of
// Phase 2.8 (`d2ad025b8`) made `recordKraken2Failure` record the removal of the interleaved halves after the kraken2
// step that read them, and left no test, because the stand-in kraken2 of the classifier tests has no mode that throws.
// In the unit tier `runTool` throws only on a cancel or a timeout, so this stand-in waits and the test cancels the
// run. KrakenRecordedRemovalPinTests holds the same order for a kraken2 that exits non-zero, which returns through
// the success path and never reaches `recordKraken2Failure`.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenCancelledSplitRemovalTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-cancelled-split")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The run is cancelled while kraken2 reads the two halves of an interleaved input. The record keeps a kraken2
    /// step that exited 130, and the removal of the halves depends on that step, with the digests the split step
    /// recorded for them. The halves are gone, and no file the record names is gone without a step that says so.
    func testACancelledKraken2LeavesTheRemovalOfTheHalvesAfterItsOwnStep() async throws {
        let kraken2 = try WaitingKraken2(root: root.appendingPathComponent("stand-in"))
        let reads = root.appendingPathComponent("interleaved/reads.fastq")
        try KrakenRecordRemoval.writeInterleavedReads(to: reads)
        let config = ClassificationConfig(
            inputFiles: [reads],
            isPairedEnd: false,
            interleavedInput: true,
            databaseName: "FixtureDB",
            databasePath: kraken2.databaseURL,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true)
        )
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)
        let run = Task { try await pipeline.classify(config: config) }

        let started = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: kraken2.started.path) }
        run.cancel()
        XCTAssertTrue(started, "the stand-in kraken2 should start before the run is cancelled")
        do {
            _ = try await run.value
            XCTFail("a cancelled run must not return a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let splitFolder = config.outputDirectory.appendingPathComponent(ClassificationPipeline.interleavedSplitDirectoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: splitFolder.path), "the halves are scratch")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.status, .cancelled)
        let split = try KrakenRecordRemoval.step("Lungfish Classification Interleaved Split", in: envelope)
        let kraken = try KrakenRecordRemoval.step("kraken2", in: envelope)
        let removal = try KrakenRecordRemoval.step(ClassificationPipeline.interleavedSplitRemovalToolName, in: envelope)
        XCTAssertEqual(split.outputs.count, 2)
        XCTAssertEqual(kraken.exitStatus, 130)
        XCTAssertTrue(kraken.dependsOn.contains(split.id), "kraken2 reads the halves the split step made")
        XCTAssertEqual(removal.dependsOn, [kraken.id], "the removal waits for the kraken2 step that read the halves")
        XCTAssertEqual(removal.inputs.map(\.path), split.outputs.map(\.path))
        XCTAssertEqual(removal.inputs.map(\.checksumSHA256), split.outputs.map(\.checksumSHA256), "the digests the split recorded")
        XCTAssertEqual(KrakenRecordRemoval.problems(in: envelope), [])
    }
}

/// A conda root whose stand-in micromamba answers the version probes of micromamba and kraken2, and on the classify
/// call writes `started` and waits, so the test can cancel a run that is inside kraken2.
private struct WaitingKraken2 {
    let condaManager: CondaManager
    let databaseURL: URL
    /// The file the stand-in writes once it is classifying.
    let started: URL

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: databaseURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        started = root.appendingPathComponent("kraken2-started")
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script(started: started).write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    private static func script(started: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
        [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
        shift
        if [ "$1" = "-n" ]; then shift; shift; fi
        tool="$1"; shift
        [ "$tool" = "kraken2" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
        if [ "$1" = "--version" ]; then echo "Kraken version 2.1.3"; exit 0; fi
        echo "classifying" > "\(started.path)"
        sleep 30
        exit 0
        """
    }
}
