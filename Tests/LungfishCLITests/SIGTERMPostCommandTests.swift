// SIGTERMPostCommandTests.swift - A command reads a SIGTERM post as a cancel before its handler has run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane FXS (SWIFT, review A54 Finding 2, brief item 3). The app signals a command's whole group at
// once, so a tool that got the same SIGTERM can end its unit before the command has run its handler. The
// kernel notes the post at the `kill`, and `SIGTERMCancellation.signalCaught` reads that note beside the
// handler's count. `kraken2 classify` and `taxtriage run` hand the flag to the analysis run executor as its
// `cancelRequested`, so a unit that failed behind a post must end the run as cancelled with exit 125.
//
// Each test runs the whole command in this process on a stand-in, with no real tool. The stand-in posts the
// SIGTERM from inside the run and ignores SIGTERM again first, so the command's handler cannot run and the post
// is all there is to see. SIGTERM is ignored around the whole run, so no case can end the unit process.

import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishTestSupport
@testable import LungfishWorkflow

final class SIGTERMPostCommandTests: XCTestCase {
    private struct ToolDied: Error {}

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "sigterm-post-command")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(folder)
    }

    /// `kraken2 classify` with a pipeline that posts the group's SIGTERM and then fails, as a kraken2 child
    /// does when it ends on the same signal first (`ClassifyCommand.swift`, `cancelRequested`).
    func testClassifyEndsAsACancelWhenItsPipelineFailsBehindAPostedSIGTERM() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let reads = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let databaseFolder = folder.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseFolder, withIntermediateDirectories: true)
        let database = MetagenomicsDatabaseInfo(
            name: "Viral", tool: "kraken2", version: "2026.1", sizeBytes: 1, sizeOnDisk: 1, downloadURL: nil,
            description: "stand-in", collection: nil, path: databaseFolder, isExternal: false, bookmarkData: nil,
            lastUpdated: Date(), status: .ready, recommendedRAM: 1
        )
        let command = try ClassifyCommand.parse([
            reads.path, "--db", "Viral", "--output-dir", folder.appendingPathComponent("out", isDirectory: true).path,
            "--quiet", "--no-color",
        ])

        do {
            try await command.execute { services in
                services.database = { _ in database }
                services.availableDatabases = { [database] }
                services.materializer = ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
                services.runPipeline = { _, _ in
                    signal(SIGTERM, SIG_IGN) // the command's handler is out of reach from here on
                    XCTAssertEqual(kill(getpid(), SIGTERM), 0)
                    throw ToolDied()
                }
            }
            XCTFail("a run whose pipeline failed ended with exit 0")
        } catch let exit as ExitCode {
            XCTAssertEqual(
                exit.rawValue, CLIExitCode.cancelled.exitCode.rawValue,
                "a pipeline that failed behind a posted SIGTERM is the cancel it answers (exit 125)"
            )
        }
    }

    /// `taxtriage run` on the stand-in Nextflow that fails the sample, with the group's SIGTERM posted as the
    /// run starts, as when Nextflow ends on the same signal before the command's handler has run
    /// (`TaxTriageCommand+Run.swift`, `cancelRequested`).
    func testTaxTriageEndsAsACancelWhenItsEngineFailsBehindAPostedSIGTERM() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let engine = try TaxTriageStandInEngine(
            root: folder.appendingPathComponent("engine", isDirectory: true),
            behaviour: .failsSamples(["S1"]),
            maximumWait: .seconds(60)
        )
        let reads = folder.appendingPathComponent("S1.fastq")
        let records = (1...3).map { "@S1-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try records.write(to: reads, atomically: true, encoding: .utf8)
        let database = folder.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let command = try TaxTriageCommand.RunSubcommand.parse([
            "run", "--input", reads.path, "--sample", "S1",
            "--output", folder.appendingPathComponent("output", isDirectory: true).path,
            "--db", database.path, "--nf-profile", TaxTriageStandInEngine.profile, "--max-cpus", "2", "--no-color",
        ])
        let pipeline = engine.makePipeline()

        do {
            try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({
                signal(SIGTERM, SIG_IGN) // the command's handler is out of reach from here on
                XCTAssertEqual(kill(getpid(), SIGTERM), 0)
                return pipeline
            }) {
                try await command.execute(events: AnalysisRunEvents { _ in })
            }
            XCTFail("a run whose engine failed ended with exit 0")
        } catch let exit as ExitCode {
            XCTAssertEqual(
                exit.rawValue, CLIExitCode.cancelled.exitCode.rawValue,
                "an engine that failed behind a posted SIGTERM is the cancel it answers (exit 125)"
            )
        }
        await engine.stopLeftoverProcesses()
    }
}
