// BlastSubmitSpeciesCladePlanTests.swift - The TaxTriage and NVD plans judge at species level with the taxonomy folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST-LINEAGE, BIO-BLAST-CLADE Q3. Each plan takes the installed NCBI Taxonomy's folder from its caller, and with
// none it keeps the row's own tax ID. The callers run on the real registry, so a test checks their wiring by their source
// and never reads the installed taxonomy.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

@MainActor
final class BlastSubmitSpeciesCladePlanTests: XCTestCase {
    private var scratch: URL!
    private var project: URL!
    private var taxonomy: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "blast-species-plan")
        project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        taxonomy = scratch.appendingPathComponent("ncbi-taxonomy", isDirectory: true)
        for folder in [project!, taxonomy!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try [(1, 1, "no rank"), (10912, 1, "genus"), (3432193, 10912, "species"), (28875, 3432193, "no rank"), (10941, 28875, "no rank")]
            .map { "\($0.0)\t|\t\($0.1)\t|\t\($0.2)\t|\t\t|\t8\t|\n" }.joined()
            .write(to: taxonomy.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    func testTheTaxTriagePlanJudgesAtTheSpeciesWithTheFolderAndAtTheTaxonWithout() throws {
        let organism = TaxTriageOrganism(name: "Human rotavirus A", score: 0.9, reads: 12, taxId: 10941)
        let reads = [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT")]
        func plan(_ directory: URL?) throws -> BlastSubmitPlan {
            try ViewerViewController.taxTriageBlastSubmitPlan(
                organism: organism, reads: reads, readCount: 2, accessions: ["LC912136"], projectURL: project,
                taxonomyDirectory: directory
            )
        }

        XCTAssertEqual(try plan(taxonomy).request.acceptedTaxIds, [10941, 28875, 3432193])
        XCTAssertEqual(try plan(taxonomy).request.taxId, 10941)
        XCTAssertEqual(try plan(nil).request.acceptedTaxIds, [10941])
    }

    func testTheNvdPlanJudgesAtTheSpeciesWithTheFolderAndAtTheTaxonWithout() throws {
        let hit = NvdBlastHit(
            experiment: "100", blastTask: "megablast", sampleId: "SampleA", qseqid: "NODE_1", qlen: 20,
            sseqid: "LC912136", stitle: "Human rotavirus A segment 1", taxRank: "no rank:Human rotavirus A", length: 20,
            pident: 100, evalue: 0, bitscore: 40, sscinames: "Human rotavirus A", staxids: "10941",
            blastDbVersion: "core_nt", snakemakeRunId: "run", mappedReads: 10, totalReads: 1000, statDbVersion: "1",
            adjustedTaxid: "10941", adjustmentMethod: "dominant", adjustedTaxidName: "Human rotavirus A",
            adjustedTaxidRank: "no rank", hitRank: 1, readsPerBillion: 1
        )
        func plan(_ directory: URL?) throws -> BlastSubmitPlan {
            try ViewerViewController.nvdBlastSubmitPlan(
                hit: hit, sequence: "ACGTACGTACGTACGTACGT", classificationName: "Human rotavirus A", projectURL: project,
                taxonomyDirectory: directory
            )
        }

        XCTAssertEqual(try plan(taxonomy).request.acceptedTaxIds, [10941, 28875, 3432193])
        XCTAssertEqual(try plan(taxonomy).request.taxId, 10941)
        XCTAssertEqual(try plan(nil).request.acceptedTaxIds, [10941])
    }

    /// With no project the plan refuses before it looks at the taxonomy, so a refusal never waits on the file.
    func testNoProjectRefusesBeforeTheTaxonomyIsRead() throws {
        let organism = TaxTriageOrganism(name: "Human rotavirus A", score: 0.9, reads: 12, taxId: 10941)
        XCTAssertThrowsError(
            try ViewerViewController.taxTriageBlastSubmitPlan(
                organism: organism, reads: [(id: "read_1", sequence: "ACGT")], readCount: 2, accessions: [], projectURL: nil,
                taxonomyDirectory: taxonomy
            )
        ) { XCTAssertEqual($0 as? BlastSubmitPlanError, .noProject) }
    }

    private static let viewer = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LungfishApp/Views/Viewer", isDirectory: true)

    /// The three result views pass the installed folder off the main actor.
    func testEachCallerPassesTheInstalledTaxonomyAndBuildsItsPlanOffTheMainActor() throws {
        for name in ["ViewerViewController+NaoMgs.swift", "ViewerViewController+Nvd.swift", "ViewerViewController+TaxTriage.swift"] {
            let source = try String(contentsOf: Self.viewer.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(source.contains("await Self.installedNCBITaxonomyDirectory()"), name)
            XCTAssertTrue(source.contains("await Self.blastSubmitPlanOffMainActor"), name)
        }
    }

    /// EsViritu's plan is cheap, so only its taxonomy goes off the main actor, where it reads the installed database and the
    /// installed NCBI Taxonomy. The launch itself takes the folders through that helper, not the test's stand-in.
    func testTheEsVirituCallerReadsBothInstalledDatabasesOffTheMainActor() throws {
        let source = try String(contentsOf: Self.viewer.appendingPathComponent("ViewerViewController+EsViritu.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@concurrent nonisolated static func installedEsVirituBlastTaxonomyContext"))
        XCTAssertTrue(source.contains("await EsVirituDatabaseManager.shared.installedDatabaseInfo()?.path"))
        XCTAssertTrue(source.contains("await Self.installedNCBITaxonomyDirectory()"))
        XCTAssertTrue(source.contains("= ViewerViewController.installedEsVirituBlastTaxonomyContext"))
    }
}
