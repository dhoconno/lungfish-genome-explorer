// TaxaCollectionExtractionSIGTERMReplayTests.swift - extract taxa-collection cancels on SIGTERM, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A66 M2, ARCH memo check 8 and decision C5 of 2.10. The app cancels a CLI route with
// SIGTERM and gives the command `CLIProcessLauncher.operationGrace` before SIGKILL. The command runs
// against a stand-in seqkit that writes its process ID and sleeps, with one busy thread for every
// active processor, three times. Each run ends with exit 125 inside the grace, leaves a record that
// reads `cancelled` with exit status 125, writes no taxon file and leaves no process of its tree. The
// run is the one `ViewerViewController.taxaCollectionExtractionArguments` gives the Extract button.
//
// The class launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier. It needs no real tool.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class TaxaCollectionExtractionSIGTERMReplayTests: XCTestCase {
    /// How many times the extraction cancels in one busy window. Whether the command's handler runs
    /// before its tool's death is noticed is a race a busy machine decides, so one run proves little.
    private static let repetitions = 3

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "taxa-collection-sigterm")
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testSIGTERMCancelsTheCollectionExtractionAndRecordsItCancelledWithEveryCoreBusy() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        for repetition in 1...Self.repetitions {
            let root = scratch.appendingPathComponent("run-\(repetition)", isDirectory: true)
            let fixtures = try TaxaCollectionFixtures(in: root)
            try Self.writeStandInSeqkit(in: root)
            let collection = TaxaCollectionFixtures.collection
            let outputDirectory = fixtures.singleEnd.appendingPathComponent("extracted-\(collection.id)", isDirectory: true)
            let arguments = ViewerViewController.taxaCollectionExtractionArguments(
                collection: collection, resultDirectory: fixtures.singleEnd, outputDirectory: outputDirectory
            )

            let run = try CLISIGTERMHarness.launchCLI(
                arguments,
                environment: ["LUNGFISH_CONDA_ROOT": root.appendingPathComponent("conda", isDirectory: true).path],
                testClass: Self.self
            )
            let pidFile = Self.seqkitPIDFile(in: root)
            let started = await CLISIGTERMHarness.waitForFile(pidFile)
            XCTAssertTrue(started, "run \(repetition): the stand-in seqkit never ran")
            let seqkit = await CLISIGTERMHarness.waitForProcessID(in: pidFile)

            let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
                ProvenanceRecorder.loadEnvelope(from: outputDirectory)?.status.rawValue
            })
            XCTAssertNotNil(stop.termination, "run \(repetition): the command exited")
            let record = ProvenanceRecorder.loadEnvelope(from: outputDirectory)
            XCTAssertEqual(record?.exitStatus, 125, "run \(repetition): the command exits 125")
            XCTAssertEqual(
                Array((record?.argv ?? []).dropFirst()), arguments,
                "run \(repetition): the cancelled record names the command that ran, --format json included"
            )
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])
                .filter { $0.hasPrefix(".kraken2-sources-") || $0.hasSuffix(".fastq") }
            XCTAssertEqual(leftovers, [], "run \(repetition): a cancelled extraction leaves no scratch folder and no plain FASTQ file")
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])
                .filter { $0.hasSuffix(".fastq.gz") }
            XCTAssertEqual(files, [], "run \(repetition): a cancelled extraction writes no taxon file")
            if let seqkit {
                await CLISIGTERMHarness.assertNoProcessLeft([seqkit])
            }
        }
    }

    // MARK: - Fixture

    nonisolated private static func seqkitPIDFile(in root: URL) -> URL {
        root.appendingPathComponent("conda/envs/seqkit/bin/seqkit.pid")
    }

    /// A conda root whose seqkit answers a version probe and sleeps on any other call after it wrote
    /// `$$` beside itself. The command reads the root from `LUNGFISH_CONDA_ROOT`, so the stand-in wins
    /// over a real tool.
    nonisolated private static func writeStandInSeqkit(in root: URL) throws {
        let script = """
        #!/bin/sh
        case "$*" in
          *version*) echo "seqkit v2.8.0"; exit 0 ;;
        esac
        echo $$ > "$(dirname "$0")/seqkit.pid"
        exec sleep 120
        """
        let binary = root.appendingPathComponent("conda/envs/seqkit/bin/seqkit")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }
}
