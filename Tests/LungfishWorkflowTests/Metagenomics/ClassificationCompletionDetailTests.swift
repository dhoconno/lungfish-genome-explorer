// ClassificationCompletionDetailTests.swift - The words a classifier row ends on, per outcome
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the completion and failure details of the Kraken2 and EsViritu rows.
///
/// Every expected string is the one the app's launch closures built inline
/// before the builders moved to LungfishWorkflow, so a change here changes
/// what users read in the Operations panel, and what the executor and the
/// CLI's text summary say. The Kraken2 single-sample detail is pinned in
/// `ClassificationBatchOutcomeTests`, which owns the result fixtures.
final class ClassificationCompletionDetailTests: XCTestCase {
    private func row(_ sampleId: String, status: String) -> ClassificationBatchSummaryRow {
        ClassificationBatchSummaryRow(
            sampleId: sampleId,
            status: status,
            profileState: "",
            requestedRank: "",
            resolvedRank: "",
            totalReads: "",
            classifiedReads: "",
            classifiedPercentage: "",
            speciesCount: "",
            dominantSpecies: "",
            message: ""
        )
    }

    private func evaluation(
        _ statuses: [String],
        sqliteWarning: String? = nil
    ) -> ClassificationBatchOutcomeEvaluation {
        let rows = statuses.enumerated().map { index, status in row("s\(index + 1)", status: status) }
        return ClassificationBatchOutcomePolicy.evaluate(rows: rows, sqliteWarning: sqliteWarning)
    }

    // MARK: - EsViritu, one sample

    func testEsVirituZeroHitsReadsNoViralHitsDetected() {
        XCTAssertEqual(
            ClassificationCompletionDetail.esVirituDetection(virusCount: 0, familyCount: 0),
            "No viral hits detected"
        )
    }

    func testEsVirituHitsNameTheVirusAndFamilyCounts() {
        XCTAssertEqual(
            ClassificationCompletionDetail.esVirituDetection(virusCount: 3, familyCount: 2),
            "3 viruses detected in 2 families"
        )
    }

    /// Each count noun follows its count (Phase 2.10 U34, W4). It read `1 viruses detected in 1 families`.
    func testEsVirituHitsFollowEachCountWithItsNoun() {
        let cases: [(viruses: Int, families: Int, detail: String)] = [
            (1, 1, "1 virus detected in 1 family"),
            (3, 1, "3 viruses detected in 1 family"),
            (1, 0, "1 virus detected in 0 families"),
            (2, 2, "2 viruses detected in 2 families"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ClassificationCompletionDetail.esVirituDetection(virusCount: testCase.viruses, familyCount: testCase.families),
                testCase.detail
            )
        }
    }

    // MARK: - EsViritu, a batch

    func testEsVirituBatchWithoutFailuresNamesTheCompletedShare() {
        XCTAssertEqual(
            ClassificationCompletionDetail.esVirituBatch(successCount: 3, failureCount: 0, sampleCount: 3),
            "3 of 3 samples completed"
        )
    }

    func testEsVirituPartialBatchNamesBothCounts() {
        XCTAssertEqual(
            ClassificationCompletionDetail.esVirituBatch(successCount: 2, failureCount: 1, sampleCount: 3),
            "2 completed, 1 failed"
        )
    }

    // MARK: - Kraken2, a batch

    func testKraken2BatchOfValidSamplesHasNoWarningClause() {
        let outcome = evaluation(["ok", "ok", "ok"])
        XCTAssertFalse(outcome.requiresWarningCompletion)
        XCTAssertEqual(
            ClassificationCompletionDetail.kraken2Batch(successCount: 3, sampleCount: 3, evaluation: outcome),
            "3 of 3 samples returned valid Kraken2 classifications"
        )
    }

    func testKraken2PartialBatchAppendsTheFailedCount() {
        let outcome = evaluation(["ok", "ok", "failed"])
        XCTAssertTrue(outcome.requiresWarningCompletion)
        XCTAssertEqual(
            ClassificationCompletionDetail.kraken2Batch(successCount: 2, sampleCount: 3, evaluation: outcome),
            "2 of 3 samples returned valid Kraken2 classifications; 1 sample failed"
        )
        let twoFailed = evaluation(["ok", "failed", "failed"])
        XCTAssertEqual(
            ClassificationCompletionDetail.kraken2Batch(successCount: 1, sampleCount: 3, evaluation: twoFailed),
            "1 of 3 samples returned valid Kraken2 classifications; 2 samples failed"
        )
    }

    func testKraken2BatchWithDegradedBrackenFailuresAndADatabaseWarningJoinsEachClause() {
        let outcome = evaluation(
            ["ok", "degraded", "failed"],
            sqliteWarning: "Unable to build kraken2.sqlite"
        )
        XCTAssertEqual(
            ClassificationCompletionDetail.kraken2Batch(successCount: 2, sampleCount: 3, evaluation: outcome),
            "2 of 3 samples returned valid Kraken2 classifications; "
                + "1 sample retained Kraken2 classifications but Bracken profiling degraded; "
                + "1 sample failed; Unable to build kraken2.sqlite"
        )
    }

    func testKraken2BatchWithOnlyADatabaseWarningStillAppendsIt() {
        let outcome = evaluation(["ok", "ok"], sqliteWarning: "Unable to build kraken2.sqlite")
        XCTAssertEqual(
            ClassificationCompletionDetail.kraken2Batch(successCount: 2, sampleCount: 2, evaluation: outcome),
            "2 of 2 samples returned valid Kraken2 classifications; Unable to build kraken2.sqlite"
        )
    }

    // MARK: - Every sample failed, and a cancelled batch

    func testAllFailedBatchUsesTheFirstErrorElseTheFixedText() {
        XCTAssertEqual(
            ClassificationCompletionDetail.allSamplesFailed(firstError: "kraken2 exited with status 2"),
            "kraken2 exited with status 2"
        )
        XCTAssertEqual(ClassificationCompletionDetail.allSamplesFailed(firstError: nil), "All samples failed")
    }

    func testCancelledBatchReadsBatchCancelled() {
        XCTAssertEqual(ClassificationCompletionDetail.batchCancelled, "Batch cancelled")
    }
}
