// BlastVerificationArchiveTests.swift - Saved BLAST verifications in a result folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class BlastVerificationArchiveTests: XCTestCase {

    private var resultDir: URL!

    override func setUp() async throws {
        resultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastVerificationArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: resultDir)
    }

    private func result(taxId: Int, rid: String, completedAt: Date) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "Simplexvirus humanalpha1",
            taxId: taxId,
            readResults: [
                BlastReadResult(id: "r1", verdict: .verified, topHitOrganism: "Human alphaherpesvirus 1",
                                matchesQueriedTaxon: true, topHitRelation: .clade),
                BlastReadResult(id: "r2", verdict: .error, errorMessage: BlastService.missingReadResultMessage),
            ],
            submittedAt: completedAt.addingTimeInterval(-60),
            completedAt: completedAt,
            rid: rid,
            blastProgram: "blastn",
            database: "nt"
        )
    }

    func testSaveWritesRecordAndProvenanceSidecar() throws {
        let report = resultDir.appendingPathComponent("classification.kreport")
        try Data("100.00\t1\t1\tR\t1\troot\n".utf8).write(to: report)
        let completed = Date(timeIntervalSince1970: 1_790_000_000.25)
        let request = BlastVerificationRequest(
            taxonName: "Simplexvirus humanalpha1", taxId: 3050292,
            sequences: [("r1", "ACGT"), ("r2", "ACGT")],
            acceptedTaxIds: [3050292, 10298], acceptedTaxonNames: ["Human alphaherpesvirus 1"],
            relatedTaxonNames: ["Simplexvirus"]
        )

        let url = try BlastVerificationArchive.save(
            result(taxId: 3050292, rid: "RID-A", completedAt: completed),
            request: request,
            in: resultDir,
            sourceURLs: [report],
            argv: ["lungfish-cli", "blast", "verify", "--taxid", "3050292"]
        )

        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "blast-verifications")
        XCTAssertEqual(url.lastPathComponent, "3050292-20260921T141320250Z.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".lungfish-provenance.json"))

        let record = try BlastVerificationArchive.load(url)
        XCTAssertEqual(record.result.rid, "RID-A")
        XCTAssertEqual(record.result.errorCount, 1)
        XCTAssertEqual(record.result.readResults.first?.topHitRelation, .clade)
        XCTAssertEqual(record.request?.database, "nt")
        XCTAssertEqual(record.request?.taxonomy.cladeTaxIds, [3050292, 10298])
        XCTAssertEqual(record.request?.taxonomy.relatedNames, ["Simplexvirus"])
    }

    func testLatestPicksTheNewestVerificationOfATaxon() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try BlastVerificationArchive.save(result(taxId: 3050292, rid: "OLD", completedAt: base), request: nil, in: resultDir)
        try BlastVerificationArchive.save(result(taxId: 3050292, rid: "NEW", completedAt: base.addingTimeInterval(3600)), request: nil, in: resultDir)
        try BlastVerificationArchive.save(result(taxId: 10376, rid: "EBV", completedAt: base.addingTimeInterval(7200)), request: nil, in: resultDir)

        XCTAssertEqual(BlastVerificationArchive.latest(forTaxId: 3050292, in: resultDir)?.result.rid, "NEW")
        XCTAssertEqual(BlastVerificationArchive.latest(forTaxId: 10376, in: resultDir)?.result.rid, "EBV")
        XCTAssertNil(BlastVerificationArchive.latest(forTaxId: 562, in: resultDir))

        let all = BlastVerificationArchive.entries(in: resultDir)
        XCTAssertEqual(all.map(\.taxId), [10376, 3050292, 3050292], "newest first, sidecars skipped")
        XCTAssertEqual(BlastVerificationArchive.entries(in: resultDir, taxId: 3050292).count, 2)
    }

    func testSameMillisecondSavesDoNotOverwrite() throws {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try BlastVerificationArchive.save(result(taxId: 1, rid: "A", completedAt: when), request: nil, in: resultDir)
        let second = try BlastVerificationArchive.save(result(taxId: 1, rid: "B", completedAt: when), request: nil, in: resultDir)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(BlastVerificationArchive.latest(forTaxId: 1, in: resultDir)?.result.rid, "B")
    }

    func testUnreadableRecordIsSkipped() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try BlastVerificationArchive.save(result(taxId: 7, rid: "GOOD", completedAt: base), request: nil, in: resultDir)
        let corrupt = BlastVerificationArchive.directoryURL(for: resultDir)
            .appendingPathComponent(BlastVerificationArchive.fileName(taxId: 7, date: base.addingTimeInterval(60)))
        try Data("{".utf8).write(to: corrupt)
        XCTAssertEqual(BlastVerificationArchive.latest(forTaxId: 7, in: resultDir)?.result.rid, "GOOD")
    }

    func testRelativeResultDirectoryIsSaved() throws {
        // `lungfish blast verify --result-dir kraken2-...` passes a relative path.
        let relative = URL(
            fileURLWithPath: resultDir.lastPathComponent,
            isDirectory: true,
            relativeTo: resultDir.deletingLastPathComponent()
        )
        let url = try BlastVerificationArchive.save(
            result(taxId: 9, rid: "REL", completedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            request: nil,
            in: relative
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".lungfish-provenance.json"))
        XCTAssertEqual(BlastVerificationArchive.latest(forTaxId: 9, in: resultDir)?.result.rid, "REL")
    }

    func testNoFolderMeansNoEntries() {
        XCTAssertTrue(BlastVerificationArchive.entries(in: resultDir).isEmpty)
    }
}
