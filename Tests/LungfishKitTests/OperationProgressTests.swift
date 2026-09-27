import XCTest
@testable import LungfishKit

@MainActor
final class OperationProgressTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    private func report(_ center: OperationCenter, _ id: UUID, completed: Double, total: Double = 1_000,
                        second: Double, phase: String = "download",
                        scope: OperationProgressEvidence.Scope = .overall,
                        basis: OperationProgressEvidence.Basis = .measured) {
        center.updateProgress(id: id, evidence: .init(phase: phase, scope: scope, basis: basis,
            completed: completed, total: total, unit: "bytes", timestamp: origin.addingTimeInterval(second)), detail: phase)
    }

    func testLegacyFractionNeverClaimsMeasuredPercentageOrETA() {
        let center = OperationCenter()
        let id = center.start(title: "Assembly", detail: "Starting")
        center.update(id: id, progress: 0.5, detail: "Synthetic stage")
        XCTAssertEqual(center.items[0].displayProgressLabel, "Running")
        XCTAssertNil(center.items[0].displayProgressFraction)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin))
    }

    func testScopedAndEstimatedPercentagesPreserveLifecycle() {
        let center = OperationCenter()
        let id = center.start(title: "Tool", detail: "Starting")
        report(center, id, completed: 680, second: 0, scope: .stage, basis: .toolReported)
        XCTAssertEqual(center.items[0].displayProgressLabel, "Running · 68% of stage")
        XCTAssertEqual(center.items[0].displayProgressFraction, 0.68)
        center.updateProgress(id: id, evidence: .init(phase: "work", scope: .overall,
            basis: .estimated, fraction: 0.4), detail: "Estimated")
        XCTAssertEqual(center.items[0].displayProgressLabel, "Running · ≈40%")
        center.complete(id: id, detail: "Done")
        XCTAssertEqual(center.items[0].displayProgressLabel, "Completed")
        XCTAssertNil(center.items[0].displayProgressFraction)
    }

    func testETARequiresStableFreshMeasuredOverallCounters() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        report(center, id, completed: 0, second: 0)
        report(center, id, completed: 100, second: 5)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(5)))
        report(center, id, completed: 200, second: 10)
        XCTAssertEqual(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)), 40)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(41)))
        report(center, id, completed: 200, second: 42)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(42)), "Repeated counters must not refresh a stalled rate")
    }

    func testFrequentByteObservationsStillAccumulateEnoughTimeForETA() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        for i in 0...40 {
            report(center, id, completed: Double(i * 25), total: 10_000, second: Double(i) * 0.25)
        }
        XCTAssertEqual(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)), 90)
    }

    func testRetryBackoffInvalidatesProgressAndRequiresNewRateSamples() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        for i in 0...2 { report(center, id, completed: Double(i * 100), second: Double(i * 5)) }
        XCTAssertNotNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)))
        center.recordRetry(id: id, attempt: 1, maxRetries: 3, statusCode: 429, delaySeconds: 60)
        XCTAssertEqual(center.items[0].displayProgressLabel, "Retrying")
        XCTAssertNil(center.items[0].displayProgressFraction)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)))
        report(center, id, completed: 300, second: 15)
        XCTAssertEqual(center.items[0].displayProgressFraction, 0.3)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(15)))
    }

    func testStageAndEstimatedProgressNeverPredictWorkflowCompletion() {
        for (scope, basis) in [(OperationProgressEvidence.Scope.stage, OperationProgressEvidence.Basis.measured),
                               (.overall, .estimated), (.overall, .toolReported)] {
            let center = OperationCenter()
            let id = center.start(title: "Tool", detail: "Starting")
            for i in 0...2 { report(center, id, completed: Double(i * 100), second: Double(i * 5), scope: scope, basis: basis) }
            XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)))
        }
    }

    func testChangedPhaseTotalOrRegressingCounterResetsETA() {
        for reset in 0..<3 {
            let center = OperationCenter()
            let id = center.start(title: "Download", detail: "Starting")
            for i in 0...2 { report(center, id, completed: Double(i * 100), second: Double(i * 5)) }
            XCTAssertNotNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)))
            report(center, id, completed: reset == 2 ? 50 : 300, total: reset == 1 ? 2_000 : 1_000,
                   second: 15, phase: reset == 0 ? "next" : "download")
            XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(15)))
        }
    }

    func testUnstableRatesAndInvalidEvidenceDoNotProduceETA() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        report(center, id, completed: 0, second: 0)
        report(center, id, completed: 10, second: 5)
        report(center, id, completed: 500, second: 10)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin.addingTimeInterval(10)))
        for value in [Double.nan, .infinity, -1, 1.1] {
            center.updateProgress(id: id, evidence: .init(phase: "invalid", scope: .overall,
                basis: .toolReported, fraction: value), detail: "Invalid")
            XCTAssertNil(center.items[0].displayProgressFraction)
        }
    }

    func testCounterEvidenceTakesPrecedenceAndInvalidCountersCannotFallBackToFraction() {
        let center = OperationCenter()
        let id = center.start(title: "Tool", detail: "Starting")
        center.updateProgress(id: id, evidence: .init(phase: "work", scope: .overall,
            basis: .measured, completed: 25, total: 100, fraction: 0.9), detail: "Counters")
        XCTAssertEqual(center.items[0].displayProgressFraction, 0.25)
        for (completed, total) in [(Double.nan, 100.0), (1, 0), (-1, 100), (101, 100), (1, Double.infinity)] {
            center.updateProgress(id: id, evidence: .init(phase: "work", scope: .overall,
                basis: .measured, completed: completed, total: total, fraction: 0.9), detail: "Invalid")
            XCTAssertNil(center.items[0].displayProgressFraction)
        }
    }

    func testLegacyUpdatesInvalidatePreviousEvidence() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        report(center, id, completed: 500, second: 0)
        center.update(id: id, progress: 0.8, detail: "Wrapping")
        XCTAssertNil(center.items[0].displayProgressFraction)
        report(center, id, completed: 500, second: 0)
        center.updateWithLog(id: id, progress: 0.9, detail: "Publishing")
        XCTAssertNil(center.items[0].displayProgressFraction)
        XCTAssertEqual(center.items[0].latestLogEntry?.message, "Publishing")
    }

    func testByteUpdateWithoutAnyKnownTotalClearsUnrelatedEvidence() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        report(center, id, completed: 500, second: 0)
        center.updateBytes(id: id, bytesDownloaded: 600, totalBytes: nil)
        XCTAssertNil(center.items[0].displayProgressFraction)
        XCTAssertNil(center.items[0].estimatedRemainingTime(at: origin))
        XCTAssertNil(center.items[0].totalBytes)
    }

    func testUnknownByteTotalClearsUnrelatedEvidenceAndLateUpdatesCannotChangeTerminalDetail() {
        let center = OperationCenter()
        let id = center.start(title: "Download", detail: "Starting")
        center.updateBytes(id: id, bytesDownloaded: 500, totalBytes: 1_000)
        XCTAssertEqual(center.items[0].displayProgressFraction, 0.5)
        XCTAssertEqual(center.items[0].progressEvidence?.basis, .measured)
        center.updateBytes(id: id, bytesDownloaded: 600, totalBytes: nil)
        XCTAssertEqual(center.items[0].displayProgressFraction, 0.6, "nil preserves a known transfer total")
        center.updateBytes(id: id, bytesDownloaded: 600, totalBytes: 0)
        XCTAssertNil(center.items[0].displayProgressFraction)
        center.complete(id: id, detail: "Done")
        center.updateBytes(id: id, bytesDownloaded: 900, totalBytes: 1_000)
        center.recordRetry(id: id, attempt: 1, maxRetries: 3, statusCode: 429, delaySeconds: 60)
        XCTAssertTrue(center.items[0].retryEvents.isEmpty)
        XCTAssertFalse(center.updateProgress(id: id, evidence: nil, detail: "Late"))
        XCTAssertEqual(center.items[0].detail, "Done")
    }
}
