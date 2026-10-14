// BuildDbCoreStepHandOverTests.swift - A cancel inside a build-db core keeps the steps that ended there
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// What a cancel inside a `build-db` core leaves in the root record of the analysis run whose index step ran the
/// core (2.9 R6, A18 review ruling 2 and section 4, lane S33 M3). Each case runs a real index builder over its core
/// through the executor and stops it at QA's fault point on one step boundary. The run ends `cancelled` with exit
/// 125 within 5 seconds, keeps the launch step and each step the core ended before the cancel, each as it was
/// handed over, finds each file those steps wrote on disk with its digest and size, and names no digest of a
/// database the cancel removed (BIO 4).
final class BuildDbCoreStepHandOverTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "build-db-step-hand-over")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: The executor's cancel hook (2.8 row 266)

    /// A cancel that the command asked for through the executor's `cancelRequested`, before the run's task is
    /// cancelled, as a SIGTERM counted in its handler is. The Kraken2 core reads the hook at its next check, the one
    /// before the database, so it builds no database and compacts no folder.
    func testTheKraken2CoreStopsAtTheCancelHookBeforeItsDatabase() async throws {
        let run = try await BuildDbIndexRun.run(
            .kraken2, prepared: try BuildDbIndexFixtures.kraken2(in: scratch), in: scratch,
            fault: .requestAtLine { $0.hasPrefix("Parsed ") }
        ) { hook in
            Kraken2ResultIndexer(cancelRequested: hook)
        }

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [BuildDbIndexRun.launchToolName], "the core stopped before its first step")
        try run.assertNoDigestOf("kraken2.sqlite")
        for sample in ["SRR35517702", "SRR35517703", "SRR35517705"] {
            let raw = try run.folder().appendingPathComponent("\(sample)/classification.kraken")
            XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), "\(sample) keeps its per-read output")
        }
    }

    /// The EsViritu core reads the hook at its check before each coverage table, so it builds no database and
    /// moves no BAM.
    func testTheEsVirituCoreStopsAtTheCancelHookBeforeItsDatabase() async throws {
        let run = try await BuildDbIndexRun.run(
            .esviritu, prepared: try BuildDbIndexFixtures.esViritu(in: scratch), in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch),
            fault: .requestAtLine { $0.hasSuffix("detection rows from EsViritu results") }
        ) { hook in
            EsVirituResultIndexing(cancelRequested: hook)
        }

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [BuildDbIndexRun.launchToolName], "the core stopped before its first step")
        try run.assertNoDigestOf("esviritu.sqlite")
        let bam = try run.folder().appendingPathComponent("SRR35517705/SRR35517705_temp/SRR35517705.third.filt.sorted.bam")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bam.path), "the BAM stays where EsViritu left it")
    }

    /// The TaxTriage core reads the hook at its check before the database, so it builds none and its cleanup
    /// removes nothing.
    func testTheTaxTriageCoreStopsAtTheCancelHookBeforeItsDatabase() async throws {
        let run = try await BuildDbIndexRun.run(
            .taxtriage, prepared: try BuildDbIndexFixtures.taxTriage(in: scratch), in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch),
            fault: .requestAtLine { $0.hasPrefix("Parsed ") }
        ) { hook in
            TaxTriageResultIndexer(cancelRequested: hook)
        }

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [BuildDbIndexRun.launchToolName], "the core stopped before its first step")
        try run.assertNoDigestOf("taxtriage.sqlite")
        try run.assertEachGoneFileHasARemovalStep()
    }

    // MARK: Kraken2, each folder's compaction

    /// A cancel once the first sample folder's index and gzip steps went over. The check before the next
    /// folder ends the core, so the record keeps those two steps and the later folders keep their raw output.
    func testAKraken2CancelAfterTheFirstFolderKeepsItsCompactionSteps() async throws {
        let run = try await kraken2Run(cancellingAfter: "gzip")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.buildStepNamesBesideTheRemovals(), ["lungfish-kraken2-index", "gzip"])
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertNoDigestOf("kraken2.sqlite")
        for sample in ["SRR35517703", "SRR35517705"] {
            let raw = try run.folder().appendingPathComponent("\(sample)/classification.kraken")
            XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), "\(sample) keeps its per-read output")
        }
    }

    /// A cancel once the removal step of the cleanup went over, which the check before the record sees. The
    /// record keeps every compaction and the removal step, and names no database.
    func testAKraken2CancelBeforeTheRecordKeepsEachCompactionAndTheRemoval() async throws {
        let run = try await kraken2Run(cancellingAfter: ClassificationPipeline.kraken2OutputRemovalToolName)

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [
            BuildDbIndexRun.launchToolName,
            "lungfish-kraken2-index", "gzip", "lungfish-kraken2-index", "gzip", "lungfish-kraken2-index", "gzip",
            ClassificationPipeline.kraken2OutputRemovalToolName,
        ])
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertEachGoneFileHasARemovalStep()
        try run.assertNoDigestOf("kraken2.sqlite")
    }

    // MARK: EsViritu, the BAM move and the samtools passes

    /// A cancel once the BAM move went over (plan decision E7). The read count pass ends at its next check, so
    /// the record keeps the move, whose outputs are on disk with the digests it recorded.
    func testAnEsVirituCancelAfterTheMoveKeepsTheMove() async throws {
        let run = try await esVirituRun(cancellingAfter: "Lungfish EsViritu BAM Relocation")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.buildStepNamesBesideTheRemovals(), ["Lungfish EsViritu BAM Relocation"])
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertNoDigestOf("esviritu.sqlite")
    }

    /// A cancel once the first samtools step, the header probe, went over at its append.
    func testAnEsVirituCancelAfterTheFirstSamtoolsStepKeepsIt() async throws {
        let run = try await esVirituRun(cancellingAfter: "samtools")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.buildStepNamesBesideTheRemovals(), ["Lungfish EsViritu BAM Relocation", "samtools"])
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertNoDigestOf("esviritu.sqlite")
    }

    /// A cancel once the removal step of the moved BAMs' old paths went over, which the check before the record
    /// sees. The record keeps the move, every samtools step and the removal step.
    func testAnEsVirituCancelBeforeTheRecordKeepsTheMoveThePassesAndTheRemoval() async throws {
        let run = try await esVirituRun(cancellingAfter: "Lungfish EsViritu BAM Relocation Source Removal")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(
            try run.stepNames(),
            [BuildDbIndexRun.launchToolName, "Lungfish EsViritu BAM Relocation"] + Array(repeating: "samtools", count: 7)
                + ["Lungfish EsViritu BAM Relocation Source Removal"]
        )
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertEachGoneFileHasARemovalStep()
        try run.assertNoDigestOf("esviritu.sqlite")
    }

    // MARK: TaxTriage, the samtools passes, the build and its cleanup

    /// A cancel once the first samtools step went over at its append. The pass ends at the next BAM, before
    /// the database is kept, and the cleanup never starts.
    func testATaxTriageCancelAfterTheFirstSamtoolsStepKeepsIt() async throws {
        let run = try await taxTriageRun(cancellingAfter: "samtools")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.buildStepNamesBesideTheRemovals(), ["samtools"])
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertNoDigestOf("taxtriage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try run.folder().appendingPathComponent("count/S.fastq.gz").path))
    }

    /// A cancel once the build step went over, after the core kept the database and before its cleanup starts.
    /// The cleanup's first check ends the core, so the record keeps every samtools step and the build step, the
    /// database is on disk with the build step's digest, and nothing was removed.
    func testATaxTriageCancelAfterTheBuildKeepsTheDatabaseAndRemovesNothing() async throws {
        let run = try await taxTriageRun(cancellingAfter: "lungfish build-db taxtriage")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(
            try run.stepNames(),
            [BuildDbIndexRun.launchToolName] + Array(repeating: "samtools", count: 40) + ["lungfish build-db taxtriage"]
        )
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertEachGoneFileHasARemovalStep()
        let database = try run.folder().appendingPathComponent("taxtriage.sqlite")
        XCTAssertTrue(try run.record().steps.last?.outputs.contains { BuildDbIndexRun.key($0.path) == BuildDbIndexRun.key(database.path) } == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try run.folder().appendingPathComponent("count/S.fastq.gz").path))
    }

    // MARK: Runs

    private func kraken2Run(cancellingAfter step: String) async throws -> BuildDbIndexRun {
        try await BuildDbIndexRun.run(
            .kraken2, prepared: try BuildDbIndexFixtures.kraken2(in: scratch), in: scratch, fault: .cancelAfterStep(step)
        ) { _ in
            Kraken2ResultIndexer()
        }
    }

    private func esVirituRun(cancellingAfter step: String) async throws -> BuildDbIndexRun {
        try await BuildDbIndexRun.run(
            .esviritu, prepared: try BuildDbIndexFixtures.esViritu(in: scratch), in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch), fault: .cancelAfterStep(step)
        ) { _ in
            EsVirituResultIndexing()
        }
    }

    private func taxTriageRun(cancellingAfter step: String) async throws -> BuildDbIndexRun {
        try await BuildDbIndexRun.run(
            .taxtriage, prepared: try BuildDbIndexFixtures.taxTriage(in: scratch), in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch), fault: .cancelAfterStep(step)
        ) { _ in
            TaxTriageResultIndexer()
        }
    }
}
