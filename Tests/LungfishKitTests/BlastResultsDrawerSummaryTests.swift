// BlastResultsDrawerSummaryTests.swift - The summary line of the BLAST results pane reads one sentence at a time
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishKit

/// Phase 3.2 lane KRAKENCORE. BLAST-DOUBLE-PERIOD (W-37, S4): a Not specific result whose search file sits beside it read
/// `...apart from them.. Collected 43 s after the first send`. BIO-BLAST-DATABASES item 7: the summary names the database NCBI
/// searched when it is not the one the search asked for. A record that carries what NCBI reported is made the way a reader of a
/// saved record makes it, from its JSON, so a build without the fields fails these at run time.
@MainActor
final class BlastResultsDrawerSummaryTests: XCTestCase {
    private func notSpecific(database: String) -> BlastVerificationResult {
        let tie = BlastTieSummary(
            hitListSize: 500, hitsReturned: 500, bestBitScore: 139.619, tied: 4, inClade: 1, outside: 3,
            runsPastList: false, outsideExamples: ["Expression vector pHR_SFFV", "synthetic construct"]
        )
        return BlastVerificationResult(
            taxonName: "Human immunodeficiency virus 1", taxId: 11676,
            readResults: [BlastReadResult(id: "read_1", verdict: .verified, matchesQueriedTaxon: true, tieSummary: tie)],
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: database
        )
    }

    /// `result` as a saved record that names the database and version NCBI reported.
    private func saved(_ result: BlastVerificationResult, reporting database: String) throws -> BlastVerificationResult {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        object["reportedDatabase"] = database
        object["blastVersion"] = "BLASTN 2.17.0+"
        return try JSONDecoder().decode(BlastVerificationResult.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// A search file that ended `seconds` after its first accepted send, which is what puts the collected words on the pane.
    private static func finishedSearchFile(collectedAfter seconds: TimeInterval) -> BlastSearchFile {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let request = BlastVerificationRequest(taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt")
        var file = BlastSearchFile(
            origin: .standIn, createdAt: start, submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .done
        file.copies[0].rid = "RID-1"
        file.copies[0].postAt = start.addingTimeInterval(3_600)
        file.winnerOrdinal = file.copies[0].ordinal
        file.ending = BlastSearchFile.Ending(state: .done, at: start.addingTimeInterval(3_600 + seconds), words: "Collected")
        return file
    }

    private func summary(of result: BlastVerificationResult, recordURL: URL?) -> String {
        let tab = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        tab.showResults(result, recordURL: recordURL)
        tab.layoutSubtreeIfNeeded()
        return tab.summaryLabel.stringValue
    }

    /// BLAST-DOUBLE-PERIOD. The Not specific sentence ends in a period and the collected words follow it, so they meet at one.
    func testANotSpecificResultWithASearchFileReadsOnePeriodBetweenSentences() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BlastSearchStore(folder: folder).save(Self.finishedSearchFile(collectedAfter: 43))

        let shared = notSpecific(database: "core_nt")
        XCTAssertEqual(shared.confidence, .notSpecific)
        let text = summary(of: shared, recordURL: folder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
        XCTAssertFalse(text.contains(".."), text)
        XCTAssertTrue(text.contains("apart from them. Collected"), text)
    }

    /// BIO item 7. A record that asked for `nt` and was searched on `core_nt` says so in the summary, in words a person reads.
    func testTheSummaryNamesTheDatabaseNCBISearchedWhenItDiffers() throws {
        let reported = try saved(notSpecific(database: "nt"), reporting: "core_nt")
        let text = summary(of: reported, recordURL: nil)
        XCTAssertTrue(text.contains("NCBI searched core_nt, not the nt this search asked for."), text)
        XCTAssertFalse(text.contains(".."), text)
    }

    /// The same database asked and reported adds no words. It passes at the base by design, since it guards the common case.
    func testTheSummaryAddsNoWordsWhenNCBISearchedTheDatabaseAsked() throws {
        let same = try saved(notSpecific(database: "core_nt"), reporting: "core_nt")
        XCTAssertFalse(summary(of: same, recordURL: nil).contains("NCBI searched"))
    }
}
