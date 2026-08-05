import XCTest
@testable import LungfishWorkflow

final class SavontRetryPolicyTests: XCTestCase {
    func testKnownCrashStatusesRetryWithOneThreadWhenParallel() {
        for status: Int32 in [-11, 11, 134, 136, 137, 138, 139] {
            XCTAssertEqual(
                SavontRetryPolicy.decision(
                    exitCode: status,
                    attemptedThreads: 4,
                    attemptedSingleStrand: false,
                    stderr: ""
                ),
                .singleThread,
                "status \(status)"
            )
        }
    }

    func testCrashStatusesDoNotRetryWhenAlreadySingleThread() {
        for status: Int32 in [-11, 11, 134, 136, 137, 138, 139] {
            XCTAssertEqual(
                SavontRetryPolicy.decision(
                    exitCode: status,
                    attemptedThreads: 1,
                    attemptedSingleStrand: false,
                    stderr: ""
                ),
                .none,
                "status \(status)"
            )
        }
    }

    func testLowBidirectionalSNPmerFailureRetriesSingleStrand() {
        XCTAssertEqual(
            SavontRetryPolicy.decision(
                exitCode: 1,
                attemptedThreads: 3,
                attemptedSingleStrand: false,
                stderr: "Less than 0.1% of SNPmers were bidirectional; retry with --single-strand"
            ),
            .singleStrand
        )
    }

    func testRepeatedLowBidirectionalSNPmerFailureBecomesEmptyClusters() {
        XCTAssertEqual(
            SavontRetryPolicy.decision(
                exitCode: 1,
                attemptedThreads: 1,
                attemptedSingleStrand: true,
                stderr: "LESS THAN 0.1% OF SNPMERS; use --SINGLE-STRAND"
            ),
            .emptyClusters
        )
    }

    func testLowBidirectionalMessageRequiresNonzeroExitAndBothPhrases() {
        let completeMessage = "less than 0.1% of snpmers; use --single-strand"
        XCTAssertEqual(
            SavontRetryPolicy.decision(
                exitCode: 0,
                attemptedThreads: 4,
                attemptedSingleStrand: false,
                stderr: completeMessage
            ),
            .none
        )
        XCTAssertEqual(
            SavontRetryPolicy.decision(
                exitCode: 1,
                attemptedThreads: 4,
                attemptedSingleStrand: false,
                stderr: "less than 0.1% of snpmers"
            ),
            .none
        )
        XCTAssertEqual(
            SavontRetryPolicy.decision(
                exitCode: 1,
                attemptedThreads: 4,
                attemptedSingleStrand: false,
                stderr: "try --single-strand"
            ),
            .none
        )
    }

    func testLowBidirectionalFailureTakesPrecedenceOverCrashRetry() {
        XCTAssertEqual(
            SavontRetryPolicy.decision(
                exitCode: 139,
                attemptedThreads: 4,
                attemptedSingleStrand: false,
                stderr: "less than 0.1% of snpmers; use --single-strand"
            ),
            .singleStrand
        )
    }

    func testUnrecognizedFailureDoesNotRetry() {
        for status: Int32 in [1, 2, 130, 143] {
            XCTAssertEqual(
                SavontRetryPolicy.decision(
                    exitCode: status,
                    attemptedThreads: 8,
                    attemptedSingleStrand: false,
                    stderr: "ordinary failure"
                ),
                .none,
                "status \(status)"
            )
        }
    }
}
