// TaxonomyExtractionClipboardSIGTERMReplayTests.swift - The clipboard extraction's command cancels, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.11 M2, decision C5 of 2.10 and PLAN X14. The extraction sheet's clipboard row runs
// `lungfish-cli extract reads --by-classifier` into a scratch folder of the project's `.tmp`
// (`ClassifierExtractionCopyRoute`). The command runs against a stand-in seqkit that writes its process ID
// and sleeps, with one busy thread for every active processor, three times in each test.
//
// - Through `CLISIGTERMHarness`, the command exits 125 inside `CLIProcessLauncher.operationGrace` after
//   SIGTERM, records its run as cancelled, publishes no file and leaves no process of its tree.
// - Through the app's route on the real transport, a cancel of the row's task stops the command inside
//   the grace, ends in `CancellationError` and leaves no scratch folder and no process.
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
final class TaxonomyExtractionClipboardSIGTERMReplayTests: XCTestCase {
    /// How many times the extraction cancels in one busy window, since one run proves little.
    private static let repetitions = 3

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "clipboard-sigterm")
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testSIGTERMCancelsTheClipboardCommandAndRecordsItCancelledWithEveryCoreBusy() async throws {
        let load = try await Self.busyCores()
        defer { load.stop() }
        for repetition in 1...Self.repetitions {
            let (route, root) = try makeRoute(repetition)
            let run = try CLISIGTERMHarness.launchCLI(route.arguments, environment: Self.environment(root), testClass: Self.self)
            let pidFile = Self.seqkitPIDFile(in: root)
            let started = await CLISIGTERMHarness.waitForFile(pidFile)
            XCTAssertTrue(started, "run \(repetition): the stand-in seqkit never ran")
            let seqkit = await CLISIGTERMHarness.waitForProcessID(in: pidFile)

            let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
                ProvenanceRecorder.loadEnvelope(from: route.scratchDirectory)?.status.rawValue
            })
            XCTAssertNotNil(stop.termination, "run \(repetition): the command exited")
            let record = ProvenanceRecorder.loadEnvelope(from: route.scratchDirectory)
            XCTAssertEqual(record?.exitStatus, 125, "run \(repetition): the command exits 125")
            // The command records its canonical form, `--output` for `-o`, which names the same extraction.
            let argv = record?.argv ?? []
            XCTAssertTrue(
                argv.contains("--by-classifier") && argv.contains(route.scratchFile.path),
                "run \(repetition): the record names the extraction into the scratch file, \(argv)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: route.scratchFile.path), "run \(repetition): a cancelled command publishes no file")
            if let seqkit {
                await CLISIGTERMHarness.assertNoProcessLeft([seqkit])
            }
        }
    }

    func testCancellingTheClipboardRouteLeavesNoScratchFolderWithEveryCoreBusy() async throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let load = try await Self.busyCores()
        defer { load.stop() }
        for repetition in 1...Self.repetitions {
            let (route, root) = try makeRoute(repetition)
            let environment = Self.environment(root)
            let task = Task.detached {
                try await route.run(operationID: UUID(), cliURLOverride: cli, environmentAdditions: environment)
            }
            let pidFile = Self.seqkitPIDFile(in: root)
            let started = await CLISIGTERMHarness.waitForFile(pidFile)
            XCTAssertTrue(started, "run \(repetition): the stand-in seqkit never ran")
            let seqkit = await CLISIGTERMHarness.waitForProcessID(in: pidFile)

            let cancelledAt = ContinuousClock.now
            task.cancel()
            let result = await task.result
            let elapsed = ContinuousClock.now - cancelledAt
            switch result {
            case .success(let outcome):
                XCTFail("run \(repetition): the cancelled route delivered \(outcome)")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "run \(repetition): \(error)")
            }
            XCTAssertLessThanOrEqual(elapsed, CLISIGTERMHarness.operationGrace, "run \(repetition): the command stops inside the grace")
            XCTAssertFalse(FileManager.default.fileExists(atPath: route.scratchDirectory.path), "run \(repetition): the route leaves no scratch folder")
            if let seqkit {
                await CLISIGTERMHarness.assertNoProcessLeft([seqkit])
            }
        }
    }

    // MARK: - Fixture

    /// The clipboard route the sheet makes for taxon 20 of a new single-end fixture, with its stand-in seqkit.
    private func makeRoute(_ repetition: Int) throws -> (ClassifierExtractionCopyRoute, URL) {
        let root = scratch.appendingPathComponent("run-\(repetition)", isDirectory: true)
        let fixtures = try TaxaCollectionFixtures(in: root)
        try Self.writeStandInSeqkit(in: root)
        let context = TaxonomyReadExtractionAction.Context(
            tool: .kraken2,
            resultPath: fixtures.singleEnd,
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [TaxaCollectionFixtures.speciesB])],
            suggestedName: "my-extract"
        )
        let route = try XCTUnwrap(try ClassifierExtractionCopyRoute.make(
            destination: .clipboard(format: .fastq, cap: TaxonomyReadExtractionAction.clipboardReadCap),
            context: context,
            options: ExtractionOptions(format: .fastq)
        ))
        return (route, root)
    }

    /// One busy thread for every core, all spinning.
    private static func busyCores() async throws -> BusyCores {
        let load = BusyCores()
        load.start()
        let busy = await LungfishTestSupport.waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")
        return load
    }

    nonisolated private static func environment(_ root: URL) -> [String: String] {
        ["LUNGFISH_CONDA_ROOT": root.appendingPathComponent("conda", isDirectory: true).path]
    }

    nonisolated private static func seqkitPIDFile(in root: URL) -> URL {
        root.appendingPathComponent("conda/envs/seqkit/bin/seqkit.pid")
    }

    /// A conda root whose seqkit answers a version probe and sleeps on any other call after it wrote
    /// `$$` beside itself. The command reads the root from `LUNGFISH_CONDA_ROOT`.
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
