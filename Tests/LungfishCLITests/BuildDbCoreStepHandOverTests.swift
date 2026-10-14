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
}
