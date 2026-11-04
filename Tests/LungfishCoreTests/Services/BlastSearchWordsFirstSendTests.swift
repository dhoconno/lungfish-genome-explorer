// BlastSearchWordsFirstSendTests.swift - Row 7 counts the time from the first send
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, BIO review 2 should-fix SF1. A search file is made before its first Put goes out, and the first copy's
// `postAt` is set when NCBI accepts the Put, so "after the first send" counts from `postAt`. A busy answer's waits or a quit
// before the next launch must not lengthen it.

import XCTest
@testable import LungfishCore

final class BlastSearchWordsFirstSendTests: XCTestCase {
    func testCollectedCountsFromTheFirstAcceptedSend() {
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
        file.ending = BlastSearchFile.Ending(state: .done, at: start.addingTimeInterval(3_900), words: "Collected")

        let row = BlastSearchWords.collected(after: 300, sends: 1)
        XCTAssertEqual(BlastSearchWords.collected(in: file), row, "five minutes after the send, not an hour and five after the file")
        let lead = row.components(separatedBy: " after the first send").first ?? ""
        let pane = BlastSearchWords.collectedOnThePane(in: file) ?? ""
        XCTAssertTrue(pane.hasPrefix(lead + " after the first send. "), pane)
    }
}
