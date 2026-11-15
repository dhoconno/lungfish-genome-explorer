// RNASeqExportScaleTests.swift - A whole transcriptome exports in seconds (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The first GD run of C5 imported 25 salmon folders of 60,371 features, and `rnaseq export` of that result ran 3 min 21 s at
// 100% CPU before it was ended. The join found each row of each table with a scan of the table, so its time grew with the
// square of the gene count. A table of 20,000 genes has to join, and export, inside the standard wait budget.

import XCTest
import os
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqExportScaleTests: RNASeqExportTestCase {
    private let geneCount = 20_000

    /// Runs `work` away from the test's task and returns what it made, or nil when the standard budget ran out first. The
    /// work runs outside the lock, so the wait can still time out while it runs.
    private func inTime<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T? {
        let outcome = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        Task.detached {
            let result = Result { try work() }
            outcome.withLock { $0 = result }
        }
        let finished = await waitUntil(budget: .standard) { outcome.withLock { $0 != nil } }
        guard finished else { return nil }
        return try outcome.withLock { $0 }?.get()
    }

    private var late: String { "did not finish inside the \(WaitBudget.standard.name) budget of \(WaitBudget.standard.seconds) s." }

    /// One result of 20,000 genes goes through the whole export, and every gene is a row of `counts.tsv`.
    func testTwentyThousandGenesExportInsideTheStandardBudget() async throws {
        let genes = (0..<geneCount).map { "G\($0)" }
        let groups = ["S1": "TB", "S2": "TB", "S3": "HIV", "S4": "HIV"]
        let result = try make(.init(name: "whole", samples: ["S1", "S2", "S3", "S4"], genes: genes, groups: groups))
        let out = root.appendingPathComponent("out", isDirectory: true)
        let settings = RNASeqExportSettings(design: ["group"], contrasts: [.init(factor: "group", numerator: "TB", denominator: "HIV")])
        let written = try await inTime {
            try RNASeqExport.run(results: [result], sheet: nil, settings: settings, output: out, argv: ["lungfish-cli", "rnaseq", "export"])
        }
        XCTAssertNotNil(written, "Exporting \(geneCount) genes \(late)")
        guard written != nil else { return }
        let counts = try String(contentsOf: out.appendingPathComponent("counts.tsv"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(counts.count, geneCount + 1)
        XCTAssertEqual(counts.last, "G\(geneCount - 1)\t\(10 * geneCount)\t\(10 * geneCount + 1)\t\(10 * geneCount + 2)\t\(10 * geneCount + 3)")
    }

    /// The second result lists the genes in the opposite order, so a join by position puts every count in another gene's row.
    func testTwentyThousandGenesOfTwoResultsJoinInsideTheStandardBudgetWithEveryCountInItsRow() async throws {
        let genes = (0..<geneCount).map { "G\($0)" }
        let first = try make(.init(name: "first", samples: ["S1", "S2"], genes: genes))
        let second = try make(.init(name: "second", samples: ["T1", "T2", "T3"], genes: genes.reversed(), shift: 100))
        let read = try RNASeqExportReader.read([first, second])
        let joined = try await inTime { try RNASeqExportJoin.make(read) }
        XCTAssertNotNil(joined, "Joining \(geneCount) genes of two results \(late)")
        guard let join = joined else { return }
        XCTAssertEqual(join.counts.sampleIDs, ["S1", "S2", "T1", "T2", "T3"])
        XCTAssertEqual(join.counts.rows.count, geneCount)
        var wrong: [String] = []
        for (position, row) in join.counts.rows.enumerated() {
            let reversedAt = geneCount - 1 - position
            let expected = (0..<2).map { Double(10 * (position + 1) + $0) } + (0..<3).map { Double(10 * (reversedAt + 1) + $0 + 100) }
            if row.id != "G\(position)" || row.counts != expected { wrong.append(row.id) }
        }
        XCTAssertEqual(Array(wrong.prefix(3)), [], "\(wrong.count) rows hold the counts of another gene.")
    }
}
