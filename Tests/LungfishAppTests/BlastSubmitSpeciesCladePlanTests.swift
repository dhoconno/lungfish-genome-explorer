// BlastSubmitSpeciesCladePlanTests.swift - The TaxTriage and NVD plans judge at species level with the taxonomy folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLAST-LINEAGE, BIO-BLAST-CLADE Q3. Each plan takes the installed NCBI Taxonomy's folder from its caller, and with
// none it keeps the row's own tax ID. The callers run on the real registry, so these tests call the plans with a stand-in
// folder and never read the installed taxonomy.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKitTestSupport
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

    /// BLAST-ESVIRITU-FIRST-WORD (BIO R1 lines 98-115). Each plan records what it judged at, so the pane can say so when
    /// the NCBI Taxonomy is not installed. The lineage gives `species`, the row's own tax ID gives `rowTaxId`, and a row
    /// with no tax ID is judged by its name alone. The verdict rule is the same in every case.
    func testPlanRecordsTheBasisItJudgedAt() throws {
        let reads = [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT")]
        func taxTriage(taxId: Int?, _ directory: URL?) throws -> String? {
            let organism = TaxTriageOrganism(name: "Human rotavirus A", score: 0.9, reads: 12, coverage: nil, taxId: taxId, rank: nil)
            return try ViewerViewController.taxTriageBlastSubmitPlan(
                organism: organism, reads: reads, readCount: 2, accessions: [], projectURL: project, taxonomyDirectory: directory
            ).request.judgedAt
        }
        XCTAssertEqual(try taxTriage(taxId: 10941, taxonomy), "species")
        XCTAssertEqual(try taxTriage(taxId: 10941, nil), "rowTaxId")
        XCTAssertEqual(try taxTriage(taxId: nil, taxonomy), "names")

        func nvd(_ directory: URL?) throws -> String? {
            try ViewerViewController.nvdBlastSubmitPlan(
                hit: Self.nvdHit(), sequence: "ACGTACGTACGTACGTACGT", classificationName: "Human rotavirus A",
                projectURL: project, taxonomyDirectory: directory
            ).request.judgedAt
        }
        XCTAssertEqual(try nvd(taxonomy), "species")
        XCTAssertEqual(try nvd(nil), "rowTaxId")

        func naoMgs(taxId: Int, _ directory: URL?) throws -> String? {
            try ViewerViewController.naoMgsBlastSubmitPlan(
                taxonName: "Human rotavirus A", taxId: taxId, readCount: 2, reads: [Self.naoMgsRead()], projectURL: project,
                taxonomyDirectory: directory
            ).request.judgedAt
        }
        XCTAssertEqual(try naoMgs(taxId: 10941, taxonomy), "species")
        XCTAssertEqual(try naoMgs(taxId: 10941, nil), "rowTaxId")
        XCTAssertEqual(try naoMgs(taxId: 0, taxonomy), "names")
    }

    /// The lineage function is what makes a context `species`, and it gives none when the taxonomy gives no lineage, so
    /// each caller names its own fallback.
    func testTheLineageContextSaysItWasJudgedAtTheSpecies() {
        let names = ["Human rotavirus A"]
        XCTAssertEqual(NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: names, taxonomyDirectory: taxonomy)?.basis, .species)
        XCTAssertNil(NCBITaxonomyLineage.blastTaxonomyContext(of: 10941, names: names, taxonomyDirectory: nil))
    }

    /// The leaf takes the option the viewer's plan sends, records it among the explicit options and builds a request
    /// that carries it. A value that is no basis is refused, where it used to be dropped without a word.
    func testTheLeafParsesJudgedAtAndRecordsIt() throws {
        let plan = try ViewerViewController.taxTriageBlastSubmitPlan(
            organism: TaxTriageOrganism(name: "Human rotavirus A", score: 0.9, reads: 12, taxId: 10941),
            reads: [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT")], readCount: 2, accessions: [], projectURL: project,
            taxonomyDirectory: nil
        )
        let command = try RecordedCLICommand.parse(plan.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertEqual(command.judgedAt, "rowTaxId", "the viewer's plan sends what it judged at")
        XCTAssertEqual(command.makeRequest(sequences: []).judgedAt, .rowTaxId)
        let staged = StagedQuery(url: URL(fileURLWithPath: "/tmp/query.fasta"), sha256: "00", sequences: [])
        guard case .string(let recorded)? = command.explicitOptions(query: staged)["judgedAt"] else {
            return XCTFail("judgedAt is not among the explicit options the record keeps")
        }
        XCTAssertEqual(recorded, "rowTaxId")

        let base = ["--query", "/tmp/query.fasta", "--output", "/tmp/out"]
        XCTAssertNoThrow(try BlastCommand.SubmitSubcommand.parse(base + ["--judged-at", "names"]))
        XCTAssertThrowsError(try BlastCommand.SubmitSubcommand.parse(base + ["--judged-at", "genus"])) {
            XCTAssertTrue(BlastCommand.SubmitSubcommand.message(for: $0).contains("species, rowTaxId or names"))
        }
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

    private static func nvdHit() -> NvdBlastHit {
        NvdBlastHit(
            experiment: "100", blastTask: "megablast", sampleId: "SampleA", qseqid: "NODE_1", qlen: 20,
            sseqid: "LC912136", stitle: "Human rotavirus A segment 1", taxRank: "no rank:Human rotavirus A", length: 20,
            pident: 100, evalue: 0, bitscore: 40, sscinames: "Human rotavirus A", staxids: "10941",
            blastDbVersion: "core_nt", snakemakeRunId: "run", mappedReads: 10, totalReads: 1000, statDbVersion: "1",
            adjustedTaxid: "10941", adjustmentMethod: "dominant", adjustedTaxidName: "Human rotavirus A",
            adjustedTaxidRank: "no rank", hitRank: 1, readsPerBillion: 1
        )
    }

    private static func naoMgsRead() -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: "S1", seqId: "read_1", taxId: 10941, bestAlignmentScore: 40,
            cigar: "20M", queryStart: 0, queryEnd: 20, refStart: 0, refEnd: 20,
            readSequence: "ACGTACGTACGTACGTACGT", readQuality: String(repeating: "I", count: 20),
            subjectSeqId: "NC_011500.1", subjectTitle: "Human rotavirus A", bitScore: 40, eValue: 1e-5,
            percentIdentity: 100, editDistance: 0, fragmentLength: 20, isReverseComplement: false,
            pairStatus: "CP", queryLength: 20
        )
    }
}
