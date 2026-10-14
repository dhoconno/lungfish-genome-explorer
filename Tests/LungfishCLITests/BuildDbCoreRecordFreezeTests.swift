// BuildDbCoreRecordFreezeTests.swift - The steps of each build-db core in a completed root record, frozen in order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Freezes the step names, in order, of the completed root record of a run whose finalize built its viewer
/// index through a `build-db` core (lane S33 M3, A18 review section 4 item 4). A18's pins in
/// `AnalysisRunIndexStepRecordTests` compare the record with the build's own steps, which move with the cores,
/// so they do not hold this list. The cores hand each step to the root record as it ends, and a completed record
/// keeps the order it had when the builders handed the steps over once the core returned: the units' steps, then
/// the extra steps of the build, then the build step, and for TaxTriage the removal step of its cleanup last.
///
/// The EsViritu and TaxTriage builds run a stand-in samtools on the fixtures' BAMs, so their samtools steps
/// are frozen too.
final class BuildDbCoreRecordFreezeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "build-db-record-freeze")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    /// Each sample folder's index and gzip steps, then the removal step of the raw outputs, then the build.
    func testTheCompletedKraken2RecordNamesTheCompactionsThenTheRemovalThenTheBuild() async throws {
        let run = try await BuildDbIndexRun.run(.kraken2, prepared: try BuildDbIndexFixtures.kraken2(in: scratch), in: scratch) { _ in
            Kraken2ResultIndexer()
        }

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(try run.stepNames(), [
            "probe-launch",
            "lungfish-kraken2-index", "gzip",
            "lungfish-kraken2-index", "gzip",
            "lungfish-kraken2-index", "gzip",
            "Lungfish Kraken2 Output Removal",
            "lungfish build-db kraken2",
        ])
    }

    /// The BAM move, the samtools passes, the removal step of the moved BAMs' old paths, then the build.
    func testTheCompletedEsVirituRecordNamesTheMoveTheSamtoolsPassesTheRemovalThenTheBuild() async throws {
        let run = try await BuildDbIndexRun.run(
            .esviritu,
            prepared: try BuildDbIndexFixtures.esViritu(in: scratch),
            in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch)
        ) { _ in
            EsVirituResultIndexing()
        }

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(
            try run.stepNames(),
            ["probe-launch", "Lungfish EsViritu BAM Relocation"]
                // The header probe and two counts of the one BAM, then two counts for each of its two accessions.
                + Array(repeating: "samtools", count: 7)
                + ["Lungfish EsViritu BAM Relocation Source Removal", "lungfish build-db esviritu"]
        )
    }

    /// The samtools passes, the build, then the removal step of the executor's cleanup.
    func testTheCompletedTaxTriageRecordNamesTheSamtoolsPassesTheBuildThenTheRemoval() async throws {
        let run = try await BuildDbIndexRun.run(
            .taxtriage,
            prepared: try BuildDbIndexFixtures.taxTriage(in: scratch),
            in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch)
        ) { _ in
            TaxTriageResultIndexer()
        }

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(
            try run.stepNames(),
            ["probe-launch"]
                // The header probe and two counts of each of three BAMs, an idxstats of each, then two counts
                // for each of the fourteen BAM and accession pairs.
                + Array(repeating: "samtools", count: 40)
                + ["lungfish build-db taxtriage", "Lungfish TaxTriage Intermediate Removal"]
        )
    }
}
