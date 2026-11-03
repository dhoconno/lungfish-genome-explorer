// BlastSavedSearchRowPlanTests.swift - A classifier row's saved-search key is the lineage its plan records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN. The plans sit in the App and the rows' keys in LungfishIO, which the viewers can reach. These
// tests build both for one row and compare them, so a change to what a plan records fails here, not on a person's screen
// as a search that never comes back.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishApp

final class BlastSavedSearchRowPlanTests: XCTestCase {
    private var folder: URL!
    private var project: URL!
    private var result: URL!
    private let reads = (1...4).map { (id: "read_\($0)", sequence: String(repeating: "ACGT", count: $0 + 2)) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try TestTempDirectory.make(prefix: "blast-row-plan")
        project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        result = project.appendingPathComponent("Analyses/classifier-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
        try super.tearDownWithError()
    }

    private func assertKey(
        _ key: BlastSavedSearchRow?,
        isLineageOf plan: BlastSubmitPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let key = try XCTUnwrap(key, file: file, line: line)
        XCTAssertEqual(key.sourceResultURL, plan.request.sourceResultURL, file: file, line: line)
        XCTAssertEqual(key.sample, plan.request.sample, file: file, line: line)
        XCTAssertEqual(key.taxId, plan.request.taxId, file: file, line: line)
        XCTAssertEqual(key.contig, plan.request.contig, file: file, line: line)
    }

    func testATaxTriageRowsKeyIsItsPlansLineage() throws {
        let accessions = ["NC_026438.1", "NC_026435.1"]
        for taxId in [11320, nil] as [Int?] {
            let organism = TaxTriageOrganism(name: "Influenza A virus", score: 0.9, reads: 100, coverage: 50, taxId: taxId, rank: nil, sample: "S1")
            let plan = try ViewerViewController.taxTriageBlastSubmitPlan(
                organism: organism, reads: reads, readCount: 4, accessions: accessions, projectURL: project, sourceResultURL: result
            )
            try assertKey(organism.blastSavedSearchRow(accessions: accessions, sourceResultURL: result), isLineageOf: plan)
        }
    }

    func testAnEsVirituRowsKeyIsItsPlansLineage() throws {
        let detection = BlastSubmitParity.esVirituDetection(name: "Influenza A virus", species: "Alphainfluenzavirus influenzae", genus: "Alphainfluenzavirus")
        let accessions = ["NC_026433.1", "NC_026434.1"]
        let plan = try ViewerViewController.esVirituBlastSubmitPlan(
            detection: detection, reads: reads, readCount: 4, accessions: accessions, projectURL: project, sourceResultURL: result
        )
        try assertKey(detection.blastSavedSearchRow(accessions: accessions, sourceResultURL: result), isLineageOf: plan)
        XCTAssertNil(plan.request.taxId, "an EsViritu search records no tax ID")
    }

    func testAnNvdRowsKeyIsItsPlansLineage() throws {
        for adjustedTaxid in ["1234", "", "0"] {
            let hit = NvdBlastHit(
                experiment: "exp-1", blastTask: "blastn", sampleId: "S1", qseqid: "contig_1",
                qlen: 8, sseqid: "NC_000001.1", stitle: "Reference",
                taxRank: "species", length: 8, pident: 100, evalue: 0, bitscore: 50,
                sscinames: "Example virus", staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
                mappedReads: 1_000, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: adjustedTaxid,
                adjustmentMethod: "dominant", adjustedTaxidName: "Example virus", adjustedTaxidRank: "species",
                hitRank: 1, readsPerBillion: 10_000
            )
            let plan = try ViewerViewController.nvdBlastSubmitPlan(
                hit: hit, sequence: "ACGTACGTACGT", classificationName: "Example virus", projectURL: project, sourceResultURL: result
            )
            try assertKey(hit.blastSavedSearchRow(sourceResultURL: result), isLineageOf: plan)
        }
    }

    /// A NAO-MGS row draws its reads from its own sample, so the plan's list of samples is that one name.
    func testANaoMgsRowsSampleIsItsPlansLineage() throws {
        let hits = (1...4).map { read in
            NaoMgsVirusHit(
                sample: "S1", seqId: "read-\(read)", taxId: 11320,
                bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100,
                refStart: read * 100, refEnd: read * 100 + 100,
                readSequence: String(repeating: "A", count: 100), readQuality: String(repeating: "I", count: 100),
                subjectSeqId: "NC_000001.1", subjectTitle: "Taxon",
                bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
                isReverseComplement: false, pairStatus: "CP", queryLength: 100
            )
        }
        let plan = try ViewerViewController.naoMgsBlastSubmitPlan(
            taxonName: "Influenza A virus", taxId: 11320, readCount: 4, reads: hits, projectURL: project, sourceResultURL: result
        )
        let key = BlastSavedSearchRow(
            sourceResultURL: result, sample: BlastSavedSearchRow.lineageSample(of: ["S1"]), taxId: 11320, contig: nil
        )
        try assertKey(key, isLineageOf: plan)
    }

    /// A record's `@/` path resolves in the project that holds it, and a path through a symbolic link still matches.
    func testAKeyMatchesItsRecordsPortablePathAndNotAnotherResult() throws {
        let key = BlastSavedSearchRow(sourceResultURL: result, sample: "S1", taxId: nil, contig: "c")
        let recordURL = project.appendingPathComponent("blast-verifications/search/blast-result.json")
        let own = BlastSubmissionRecord.Lineage(sourceResult: "@/Analyses/classifier-run", sample: "S1", contig: "c")
        XCTAssertTrue(key.isSource(of: own, recordAt: recordURL))

        var other = own
        other.sourceResult = "@/Analyses/another-run"
        XCTAssertFalse(key.isSource(of: other, recordAt: recordURL))
        var otherSample = own
        otherSample.sample = "S2"
        XCTAssertFalse(key.isSource(of: otherSample, recordAt: recordURL))
        var taxon = own
        taxon.taxId = 7
        XCTAssertFalse(key.isSource(of: taxon, recordAt: recordURL))
        var zero = own
        zero.taxId = 0
        XCTAssertTrue(key.isSource(of: zero, recordAt: recordURL), "a tax ID of 0 reads as none")
    }
}
