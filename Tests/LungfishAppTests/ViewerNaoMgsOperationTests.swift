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
        XCTAssertTrue(readB.hasLCADisagreement, "the top hits mix Rotavirus A with Homo sapiens")

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
