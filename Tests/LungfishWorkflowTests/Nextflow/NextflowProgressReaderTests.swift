// NextflowProgressReaderTests.swift - TaxTriage's progress rule as the engine's reader applies it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9 M2. The reader moved verbatim from TaxTriageEngineProcess.swift, so these cases pin
// the rule TaxTriage's bar has followed since before 2.9, in the engine's share from 0.10 to 0.90.

import Foundation
@testable import LungfishWorkflow
import Synchronization
import XCTest

final class NextflowProgressReaderTests: XCTestCase {
    private let task = "[aa/000001] process > NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 (S1)"

    func testACompletedOrCachedTaskMovesTheBarByOneOfFifteenWithTheTrimmedLine() {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: nil, sampleCount: 1, report: reports.record)

        reader.engineLine("  \(task) [100%] 1 of 1  ")
        reader.engineLine("\(task) [  0%] 0 of 1, cached: 1")

        XCTAssertEqual(reports.messages, ["\(task) [100%] 1 of 1", "\(task) [  0%] 0 of 1, cached: 1"])
        XCTAssertEqual(reports.fractions.count, 2)
        XCTAssertEqual(reports.fractions[0], 0.10 + 1.0 / 15.0 * 0.80, accuracy: 1e-9)
        XCTAssertEqual(reports.fractions[1], 0.10 + 2.0 / 15.0 * 0.80, accuracy: 1e-9)
    }

    func testARunningTaskReportsTheBarWithoutCountingAndOtherLinesReportNothing() {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: nil, sampleCount: 1, report: reports.record)

        reader.engineLine("N E X T F L O W  ~  version 26.04.6")
        reader.engineLine("\(task) [  0%] 0 of 1")
        reader.engineLine("-[nf-core/taxtriage] Pipeline completed successfully-")

        XCTAssertEqual(reports.messages, ["\(task) [  0%] 0 of 1"])
        XCTAssertEqual(reports.fractions, [0.10])
    }

    func testTheBarStopsAtNinetyFivePercentOfTheEnginesShare() {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: nil, sampleCount: 1, report: reports.record)

        for _ in 1...20 {
            reader.engineLine("\(task) [100%] 1 of 1")
        }

        XCTAssertEqual(reports.fractions.last ?? 0, 0.10 + 0.95 * 0.80, accuracy: 1e-9)
    }

    func testAStatedTaskCountPerSampleReplacesTheEstimate() {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 2, sampleCount: 3, report: reports.record)

        reader.engineLine("\(task) [100%] 1 of 1")

        XCTAssertEqual(reports.fractions.first ?? 0, 0.10 + 1.0 / 6.0 * 0.80, accuracy: 1e-9)
    }
}

/// Collects what a reader reports.
private final class Reports: Sendable {
    private let entries = Mutex<[(fraction: Double, message: String)]>([])

    var record: @Sendable (Double, String) -> Void {
        { fraction, message in self.entries.withLock { $0.append((fraction, message)) } }
    }

    var fractions: [Double] { entries.withLock { $0.map(\.fraction) } }
    var messages: [String] { entries.withLock { $0.map(\.message) } }
}
