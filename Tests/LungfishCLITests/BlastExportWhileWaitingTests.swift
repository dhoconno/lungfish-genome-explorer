// BlastExportWhileWaitingTests.swift - blast export-table on a folder whose search has not come back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishTestSupport

final class BlastExportWhileWaitingTests: XCTestCase {
    /// UX-BLAST-WORDS, Every route, row Export. The person is told what is going on and what to run.
    func testExportWhileWaitingSaysWhy() throws {
        let folder = try TestTempDirectory.make(prefix: "blast-export-waiting")
        defer { TestTempDirectory.cleanup(folder) }
        let request = BlastVerificationRequest(taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt")
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        try BlastSearchStore(folder: folder).save(file)

        for input in [folder, folder.appendingPathComponent(BlastSubmissionRecord.recordFileName)] {
            XCTAssertThrowsError(try BlastCommand.ExportTableSubcommand.load(input), input.path) { error in
                let words = "\(error)"
                XCTAssertTrue(words.contains("still waiting at NCBI, so there is no table yet"), words)
                XCTAssertTrue(words.contains("lungfish-cli blast resume --output \(folder.path)"), words)
            }
        }
    }
}
