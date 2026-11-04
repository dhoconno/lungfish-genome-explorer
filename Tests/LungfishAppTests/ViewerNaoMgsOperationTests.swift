// ViewerNaoMgsOperationTests.swift - begin() site in ViewerViewController+NaoMgs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The NAO-MGS viewer registers one row, the BLAST verification of a taxon
// (R4). It locks no bundle. Since 2.11 A65 M2 the row records the
// `lungfish-cli blast submit` command its run executes, with the taxon, the
// subsample and the samples of the drawn reads, and the test parses it.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerNaoMgsOperationTests: XCTestCase {
    func testTaxonBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus",
            taxId: 11320,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Influenza A virus")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testTaxonBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Three reads and a count of 4 draw every read, so the samples are fixed.
        let reads = [("read_1", "S2"), ("read_2", "S1"), ("read_3", "S1")].map { Self.hit(id: $0.0, sample: $0.1) }
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Influenza A virus", taxId: 11320, readCount: 4, reads: reads, projectURL: project
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus", taxId: 11320, cliCommand: plan.cliCommand, reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), plan.arguments)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let query = URL(fileURLWithPath: command.queryPath)
        XCTAssertEqual(query.lastPathComponent, "query.fasta")
        XCTAssertTrue(query.deletingLastPathComponent().lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(query.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".tmp")
        let output = URL(fileURLWithPath: command.outputPath)
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Project.lungfish")
        XCTAssertTrue(output.lastPathComponent.hasPrefix("Influenza-A-virus-"), command.outputPath)
        XCTAssertEqual(command.label, "Influenza A virus")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.sample, "S1,S2")
        XCTAssertEqual(command.subsampleCount, 3)
        XCTAssertEqual(command.subsampleSeed, 0)
        XCTAssertNil(command.entrezQuery, "the search covers all of core_nt (3.1 BLAST-SCOPE)")
        XCTAssertEqual(command.acceptedTaxIds, [11320])
        XCTAssertEqual(command.acceptedNames, ["Influenza A virus"])
        XCTAssertNil(command.sourceResult, "a plan built without a source result records none, and NaoMgsBlastLineageTests passes the folder")
        XCTAssertNil(command.contig)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    /// 3.1 BLAST-SCOPE (BIO-NAOMGS-BLAST-SCOPE, S1). The taxon search covers all of `core_nt`, as the
    /// EsViritu, TaxTriage, Kraken 2 and NVD searches do, and judges the hits by the taxon's tax ID. A
    /// search restricted to the claimed taxon returned only records inside it, so no read could count as
    /// contradicting and the badge could only read Supported or Inconclusive.
    func testNaoMgsTaxonSearchCountsAReadWhoseBestHitIsOutsideTheTaxonAsContradicting() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-blast-scope")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let reads = [Self.readAID, Self.readBID].map { Self.hit(id: $0, sample: "S1") }
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Rotavirus A", taxId: 28875, readCount: 4, reads: reads, projectURL: project
        )
        XCTAssertNil(plan.request.entrezQuery, "the search covers all of core_nt, so a hit outside the taxon can show")
        XCTAssertEqual(plan.request.acceptedTaxIds, [28875], "the verdicts are judged against the taxon's tax ID")
        XCTAssertEqual(plan.request.acceptedNames, ["Rotavirus A"])

        let readResults = BlastService(environment: [:]).assignVerdicts(
            searchResults: [Self.readAHits, Self.readBHits], eValueThreshold: 1e-10, queriedTaxonName: "Rotavirus A",
            acceptedTaxIds: Set(plan.request.acceptedTaxIds), acceptedTaxonNames: plan.request.acceptedNames
        )
        let readA = try XCTUnwrap(readResults.first { $0.id == Self.readAID })
        let readB = try XCTUnwrap(readResults.first { $0.id == Self.readBID })
        XCTAssertEqual(readA.verdict, .verified)
        XCTAssertTrue(readA.matchesQueriedTaxon, "Human rotavirus A is Rotavirus A, so the read supports the taxon")
        XCTAssertFalse(readA.hasLCADisagreement, "every top hit is inside Rotavirus A, so none conflicts")
        XCTAssertEqual(readB.verdict, .verified, "a human hit at 100% identity and coverage is a significant match")
        XCTAssertFalse(readB.matchesQueriedTaxon, "Homo sapiens (9606) is outside Rotavirus A")
        XCTAssertFalse(readB.hasLCADisagreement, "it contradicts and its tie holds no clade record, so nothing is shared")

        let result = BlastVerificationResult(
            taxonName: "Rotavirus A", taxId: 28875, readResults: readResults,
            submittedAt: Date(timeIntervalSince1970: 0), completedAt: nil, rid: "SCOPE1", blastProgram: "blastn", database: "core_nt"
        )
        XCTAssertEqual(result.supportingCount, 1)
        XCTAssertEqual(result.contradictingCount, 1, "the human read is a measured contradiction")
        XCTAssertEqual(result.confidence, .mixed)
    }

    /// Read A of the Rotavirus A search in the walk of 2026-10-29, `1:1455:22018:13163` (141 bases), with
    /// the five hits its saved `blast-result.json` holds. Every hit aligned 140 of the 141 bases at E 1.38398e-67
    /// and bit score 255.958. NCBI returned them for the search restricted to txid28875, so 10941 lies inside
    /// 28875, and the plan passes only 28875. The titles are not in the record and repeat the organism.
    private static let readAID = "LH00642:161:23KFJ7LT4:1:1455:22018:13163"
    private static let readAHits: BlastSearchResult = {
        let hsp = BlastHSP(bitScore: 255.958, evalue: 1.38398e-67, identity: 140, alignLength: 141, queryFrom: 1, queryTo: 141)
        let hits = [
            ("LC912132", "Human rotavirus A", 10941), ("LC909836", "Rotavirus A", 28875), ("LC909803", "Rotavirus A", 28875),
            ("LC912159", "Human rotavirus A", 10941), ("PZ450839", "Rotavirus A", 28875),
        ].map { BlastHit(accession: $0.0, title: $0.1, organism: $0.1, taxId: $0.2, hsps: [hsp]) }
        return BlastSearchResult(queryId: readAID, queryLength: 141, hits: hits)
    }()

    /// Read B is built for the case: a host read whose best match is Homo sapiens (9606) at 100% identity and
    /// 100% coverage, and whose Rotavirus A hit (28875) aligns 78 of 85 bases (92%) over 85% of the read.
    private static let readBID = "read_b"
    private static let readBHits = BlastSearchResult(queryId: readBID, queryLength: 100, hits: [
        BlastHit(
            accession: "NC_000001.11", title: "Homo sapiens chromosome 1", organism: "Homo sapiens", taxId: 9606,
            hsps: [BlastHSP(bitScore: 185, evalue: 6e-46, identity: 100, alignLength: 100, queryFrom: 1, queryTo: 100)]
        ),
        BlastHit(
            accession: "LC909836", title: "Rotavirus A", organism: "Rotavirus A", taxId: 28875,
            hsps: [BlastHSP(bitScore: 105, evalue: 1e-21, identity: 78, alignLength: 85, queryFrom: 1, queryTo: 85)]
        ),
    ])

    /// A NAO-MGS read of `id` from `sample`, 20 bases long.
    private static func hit(id: String, sample: String) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: id, taxId: 11320, bestAlignmentScore: 40,
            cigar: "20M", queryStart: 0, queryEnd: 20, refStart: 0, refEnd: 20,
            readSequence: "ACGTACGTACGTACGTACGT", readQuality: String(repeating: "I", count: 20),
            subjectSeqId: "NC_026438.1", subjectTitle: "Influenza A virus", bitScore: 40, eValue: 1e-5,
            percentIdentity: 100, editDistance: 0, fragmentLength: 20, isReverseComplement: false,
            pairStatus: "CP", queryLength: 20
        )
    }

    // MARK: - Judged at species level (lane BLAST-LINEAGE, BIO-BLAST-CLADE Q2)

    private static let parent = (organism: "Rotavirus A", taxId: 28875)
    private static let label = (organism: "Human rotavirus A", taxId: 10941)
    private static let species = (organism: "Rotavirus alphagastroenteritidis", taxId: 3432193)

    /// A project and a temporary `ncbi-taxonomy` folder with the real rows for these IDs, cut to the chain.
    private static func makeSpeciesFixture(_ scratch: URL) throws -> (project: URL, taxonomy: URL) {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let taxonomy = scratch.appendingPathComponent("ncbi-taxonomy", isDirectory: true)
        for folder in [project, taxonomy] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try [
            (1, 1, "no rank"), (10912, 1, "genus"), (3432193, 10912, "species"), (28875, 3432193, "no rank"),
            (10941, 28875, "no rank"), (42567, 28875, "no rank"), (9606, 1, "species"),
        ].map { "\($0.0)\t|\t\($0.1)\t|\t\($0.2)\t|\t\t|\t8\t|\n" }.joined()
            .write(to: taxonomy.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
        try [
            (10912, "Rotavirus"), (10941, "Human rotavirus A"), (28875, "Rotavirus A"), (42567, "Rotavirus G9"),
            (3432193, "Rotavirus alphagastroenteritidis"),
        ].map { "\($0.0)\t|\t\($0.1)\t|\t\t|\tscientific name\t|\n" }.joined()
            .write(to: taxonomy.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
        return (project, taxonomy)
    }

    /// One saved read: `suffix` follows `LH00642:161:23KFJ7LT4:` in its name. A hit row gives the bases identical, the
    /// bit score and the E value.
    private static func savedRead(
        _ suffix: String,
        length: Int,
        aligned: Int,
        hits: [(accession: String, taxon: (organism: String, taxId: Int), identity: Int, bit: Double, evalue: Double)]
    ) -> BlastSearchResult {
        BlastSearchResult(queryId: "LH00642:161:23KFJ7LT4:\(suffix)", queryLength: length, hits: hits.map { row in
            BlastHit(
                accession: row.accession, title: row.taxon.organism, organism: row.taxon.organism, taxId: row.taxon.taxId,
                hsps: [BlastHSP(bitScore: row.bit, evalue: row.evalue, identity: row.identity, alignLength: aligned, queryFrom: 1, queryTo: aligned)]
            )
        })
    }

    /// A read whose five hits tie at one score, `accessions` in the saved order.
    private static func tiedRead(
        _ suffix: String, length: Int, aligned: Int, identity: Int, bit: Double, evalue: Double,
        _ accessions: [(String, (organism: String, taxId: Int))]
    ) -> BlastSearchResult {
        savedRead(suffix, length: length, aligned: aligned, hits: accessions.map { ($0.0, $0.1, identity, bit, evalue) })
    }

    private func judge(_ reads: [BlastSearchResult], taxon: String, taxId: Int, plan: BlastSubmitPlan) -> BlastVerificationResult {
        judge(reads, taxon: taxon, taxId: taxId, acceptedTaxIds: Set(plan.request.acceptedTaxIds), names: plan.request.acceptedNames)
    }

    private func judge(_ reads: [BlastSearchResult], taxon: String, taxId: Int, acceptedTaxIds: Set<Int>, names: [String]) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: taxon, taxId: taxId,
            readResults: BlastService(environment: [:]).assignVerdicts(
                searchResults: reads, eValueThreshold: 1e-10, queriedTaxonName: taxon,
                acceptedTaxIds: acceptedTaxIds, acceptedTaxonNames: names
            ),
            submittedAt: Date(timeIntervalSince1970: 0), completedAt: nil, rid: "CLADE1", blastProgram: "blastn", database: "core_nt"
        )
    }

    /// The ruling's R1 to R6, from the record of the walk of 2026-10-29, with R1 and R2 in a tied order a rerun can return.
    private static let tiedParentReads: [BlastSearchResult] = [
        tiedRead("1:1455:22018:13163", length: 141, aligned: 141, identity: 140, bit: 255.958, evalue: 1.38398e-67, [
            ("LC909836", parent), ("LC912132", label), ("LC909803", parent), ("LC912159", label), ("PZ450839", parent),
        ]),
        tiedRead("1:1207:14753:23027", length: 132, aligned: 132, identity: 132, bit: 244.878, evalue: 2.76535e-64, [
            ("PV989861", parent), ("LC912090", label), ("LC912068", label), ("LC912095", label), ("LC912067", label),
        ]),
        tiedRead("1:1103:20982:1308", length: 132, aligned: 131, identity: 131, bit: 243.0, evalue: 3.54e-63, [("LC912154", label)]),
        tiedRead("1:2205:22964:5638", length: 145, aligned: 144, identity: 144, bit: 267.0, evalue: 2.36e-70, [("LC912154", label)]),
        tiedRead("1:2423:14340:5078", length: 113, aligned: 113, identity: 113, bit: 209.8, evalue: 5.96e-50, [("LC912223", label)]),
        tiedRead("1:1131:25812:26208", length: 148, aligned: 148, identity: 146, bit: 263.0, evalue: 8.77e-70, [("LC912319", label)]),
    ]

    func testNaoMgsSubSpeciesRowCountsAHitFiledAtItsSpeciesAsSupporting() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-species-clade")
        defer { TestTempDirectory.cleanup(scratch) }
        let fixture = try Self.makeSpeciesFixture(scratch)
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Human rotavirus A", taxId: 10941, readCount: 6, reads: [Self.hit(id: "read_1", sample: "S1")],
            projectURL: fixture.project, taxonomyDirectory: fixture.taxonomy
        )
        XCTAssertEqual(Set(plan.request.acceptedTaxIds), [3432193, 28875, 10941, 42567])
        XCTAssertEqual(plan.request.acceptedNames, ["Human rotavirus A", "Rotavirus A", "Rotavirus alphagastroenteritidis"])
        XCTAssertEqual(plan.request.taxId, 10941, "the claim stays the row's own taxon")

        let result = judge(Self.tiedParentReads, taxon: "Human rotavirus A", taxId: 10941, plan: plan)

        XCTAssertEqual(result.supportingCount, 6)
        XCTAssertEqual(result.contradictingCount, 0)
        XCTAssertEqual(result.confidence, .supported)
        XCTAssertFalse(result.readResults[0].hasLCADisagreement, "R1's parent records are the same organism")
        XCTAssertFalse(result.readResults[1].hasLCADisagreement, "R2's parent record is the same organism")
    }

    func testNaoMgsSpeciesCladeAcceptsADescendantNamedOtherwiseAndNothingAboveTheSpecies() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-species-descendant")
        defer { TestTempDirectory.cleanup(scratch) }
        let fixture = try Self.makeSpeciesFixture(scratch)
        let reads = [Self.hit(id: "read_1", sample: "S1")]
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Rotavirus A", taxId: 28875, readCount: 4, reads: reads,
            projectURL: fixture.project, taxonomyDirectory: fixture.taxonomy
        )
        func readTopped(by taxon: (organism: String, taxId: Int)) -> [BlastSearchResult] {
            [Self.tiedRead("1:1103:20982:1308", length: 132, aligned: 131, identity: 131, bit: 243.0, evalue: 3.54e-63, [("X1", taxon)])]
        }

        let descendant = judge(readTopped(by: ("Rotavirus G9", 42567)), taxon: "Rotavirus A", taxId: 28875, plan: plan)
        XCTAssertEqual(descendant.supportingCount, 1, "Rotavirus G9 is a descendant named otherwise")
        let genus = judge(readTopped(by: ("Rotavirus", 10912)), taxon: "Rotavirus A", taxId: 28875, plan: plan)
        XCTAssertEqual(genus.readResults.first?.matchesQueriedTaxon, false, "the genus stays above the species")

        let labelPlan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Human rotavirus A", taxId: 10941, readCount: 4, reads: reads,
            projectURL: fixture.project, taxonomyDirectory: fixture.taxonomy
        )
        let human = [Self.tiedRead("read_b", length: 100, aligned: 100, identity: 100, bit: 185, evalue: 6e-46, [("NC_000001.11", ("Homo sapiens", 9606))])]
        let host = judge(human, taxon: "Human rotavirus A", taxId: 10941, plan: labelPlan)
        XCTAssertEqual(host.contradictingCount, 1, "a real other organism still contradicts")
    }

    /// The plan adds the scientific name of every node on the path up to the species (BLAST-LINEAGE BIO SF3), so a record
    /// the dump does not list still counts when its organism holds a path name whole, and a record of another species does not.
    func testNaoMgsPathNameCountsAnUnlistedRecordOfTheSpeciesAndNoOtherSpecies() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-path-name")
        defer { TestTempDirectory.cleanup(scratch) }
        let fixture = try Self.makeSpeciesFixture(scratch)
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Human rotavirus A", taxId: 10941, readCount: 4, reads: [Self.hit(id: "read_1", sample: "S1")],
            projectURL: fixture.project, taxonomyDirectory: fixture.taxonomy
        )
        func readTopped(by taxon: (organism: String, taxId: Int)) -> [BlastSearchResult] {
            [Self.tiedRead("1:1103:20982:1308", length: 132, aligned: 131, identity: 131, bit: 243.0, evalue: 3.54e-63, [("X1", taxon)])]
        }

        let newer = judge(
            readTopped(by: ("Rotavirus A strain RVA/Human-wt/Z1", 99_999_999)), taxon: "Human rotavirus A", taxId: 10941, plan: plan
        )
        XCTAssertEqual(newer.supportingCount, 1, "a record newer than the dump counts by the path name Rotavirus A")

        let other = judge(readTopped(by: ("Rotavirus B", 28876)), taxon: "Human rotavirus A", taxId: 10941, plan: plan)
        XCTAssertEqual(other.readResults.first?.matchesQueriedTaxon, false, "Rotavirus B is another species and holds no path name")
        XCTAssertEqual(other.contradictingCount, 1)
    }

    func testNaoMgsPlanWithoutTaxonomyAcceptsTheTaxonsOwnTaxIdOnly() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-no-taxonomy")
        defer { TestTempDirectory.cleanup(scratch) }
        let fixture = try Self.makeSpeciesFixture(scratch)
        let reads = [Self.hit(id: "read_1", sample: "S1")]

        let none = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Human rotavirus A", taxId: 10941, readCount: 4, reads: reads,
            projectURL: fixture.project, taxonomyDirectory: nil
        )
        XCTAssertEqual(none.request.acceptedTaxIds, [10941])
        XCTAssertEqual(none.request.acceptedNames, ["Human rotavirus A"])

        let noNodes = scratch.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: noNodes, withIntermediateDirectories: true)
        let missing = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Human rotavirus A", taxId: 10941, readCount: 4, reads: reads,
            projectURL: fixture.project, taxonomyDirectory: noNodes
        )
        XCTAssertEqual(missing.request.acceptedTaxIds, [10941], "a folder without nodes.dmp is no lineage")

        let noTaxId = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Taxid 0", taxId: 0, readCount: 4, reads: reads,
            projectURL: fixture.project, taxonomyDirectory: fixture.taxonomy
        )
        XCTAssertEqual(noTaxId.request.acceptedTaxIds, [], "a tax ID of 0 names no tax ID, and the older name rule judges")
    }

    /// The seven reads of the walk's row 7 (candidate c7ec1c761, RID EFD11HF1014), with the five hits each read's saved
    /// `blast-result.json` holds. Every hit is filed at 10941, its parent 28875 or the species 3432193.
    private static let walkRunReads: [BlastSearchResult] = [
        tiedRead("1:2213:5538:25956", length: 151, aligned: 151, identity: 151, bit: 279.964, evalue: 6.65268e-71, [
            ("LC912136", label), ("PX465035", parent), ("PZ019162", species), ("PV989814", parent), ("PZ450838", parent),
        ]),
        savedRead("1:2129:11905:11145", length: 141, aligned: 141, hits: [
            ("MZ096926", parent, 141, 261.498, 2.20198e-65), ("PP848779", parent, 140, 255.958, 1.02448e-63),
            ("PP848508", parent, 140, 255.958, 1.02448e-63), ("PP848501", parent, 140, 255.958, 1.02448e-63),
            ("PP861585", label, 140, 255.958, 1.02448e-63),
        ]),
        tiedRead("1:1366:29671:15208", length: 141, aligned: 141, identity: 141, bit: 261.498, evalue: 2.20198e-65, [
            ("LC912223", label), ("LC912209", label), ("LC912218", label), ("LC912207", label), ("LC912206", label),
        ]),
        tiedRead("1:2130:21274:16105", length: 121, aligned: 121, identity: 121, bit: 224.565, evalue: 2.37148e-54, [
            ("LC912223", label), ("LC912209", label), ("LC912218", label), ("LC912207", label), ("LC912206", label),
        ]),
        tiedRead("1:1310:16484:2681", length: 61, aligned: 61, identity: 61, bit: 113.766, evalue: 1.72396e-21, [
            ("LC912223", label), ("LC912218", label), ("LC912212", label), ("PX212625", species), ("PV990031", parent),
        ]),
        tiedRead("1:1397:3629:23041", length: 147, aligned: 146, identity: 146, bit: 270.731, evalue: 3.86582e-68, [
            ("LC912136", label), ("PX465035", parent), ("PZ019162", species), ("PV989814", parent), ("PZ450838", parent),
        ]),
        savedRead("1:1214:39330:1112", length: 123, aligned: 122, hits: [
            ("PP751117", parent, 122, 226.412, 6.74517e-55), ("PP751116", parent, 122, 226.412, 6.74517e-55),
            ("PZ019155", species, 121, 220.872, 3.13822e-53), ("LC912140", label, 121, 220.872, 3.13822e-53),
            ("PV753009", parent, 121, 220.872, 3.13822e-53),
        ]),
    ]

    func testNaoMgsHumanRotavirusAWalkRunReadsSupportedAtSpeciesLevel() throws {
        let scratch = try TestTempDirectory.make(prefix: "nao-mgs-walk-run")
        defer { TestTempDirectory.cleanup(scratch) }
        let fixture = try Self.makeSpeciesFixture(scratch)

        // The walk's own reading, judged by the row's own tax ID as the candidate did: the false Mixed.
        let walk = judge(Self.walkRunReads, taxon: "Human rotavirus A", taxId: 10941, acceptedTaxIds: [10941], names: ["Human rotavirus A"])
        XCTAssertEqual(walk.readResults.filter { $0.verdict == .verified }.count, 7)
        XCTAssertEqual(walk.supportingCount, 5)
        XCTAssertEqual(walk.contradictingCount, 2)
        XCTAssertEqual(walk.confidence, .mixed)
        XCTAssertEqual(
            walk.readResults.filter(\.hasLCADisagreement).count, 3,
            "reads 2129 and 1214 hold no clade record in their tie, so they contradict and are not shared"
        )

        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Human rotavirus A", taxId: 10941, readCount: 7, reads: [Self.hit(id: "read_1", sample: "S1")],
            projectURL: fixture.project, taxonomyDirectory: fixture.taxonomy
        )
        let judged = judge(Self.walkRunReads, taxon: "Human rotavirus A", taxId: 10941, plan: plan)

        XCTAssertEqual(judged.readResults.filter { $0.verdict == .verified }.count, 7)
        XCTAssertEqual(judged.supportingCount, 7)
        XCTAssertEqual(judged.contradictingCount, 0)
        XCTAssertEqual(judged.confidence, .supported)
        for read in judged.readResults {
            XCTAssertFalse(read.hasLCADisagreement, read.id)
        }
    }

    func testTaxonBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginNaoMgsBlastVerificationOperation(
            taxonName: "Influenza A virus",
            taxId: 11320,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
