// TaxTriageSummaryNotRecordedTests.swift - The summary bar of a TaxTriage result that records no run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, UX-IMPORT-BATCH item 4 widened by BIO-IMPORT-BATCH
// item 4. A result whose record lists no samples, or that has no record at all, cannot say how long the run took or
// how many samples it had. The Runtime and Samples cards then read Not recorded and not the importer's defaults
// (0.0s and one sample), and the counts of the folder stay.

import XCTest
@testable import LungfishTaxTriageUI
@testable import LungfishWorkflow

@MainActor
final class TaxTriageSummaryNotRecordedTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/nonexistent/taxtriage-summary-bar", isDirectory: true)

    /// With no samples or runtime recorded, the Runtime and Samples cards read Not recorded and the counts stay.
    func testSummaryCardsReadNotRecordedWithNoSamples() {
        let bar = TaxTriageSummaryBar()
        bar.update(organismCount: 3, runtime: nil, highConfidenceCount: 1, sampleCount: nil)

        XCTAssertEqual(value(of: "Organisms", in: bar), "3")
        XCTAssertEqual(value(of: "Runtime", in: bar), "Not recorded")
        XCTAssertEqual(value(of: "High Confidence", in: bar), "1")
        XCTAssertEqual(value(of: "Samples", in: bar), "Not recorded")
    }

    /// A run that records its runtime and its samples keeps showing them.
    func testSummaryCardsKeepTheRunsValuesWhenRecorded() {
        let bar = TaxTriageSummaryBar()
        bar.update(organismCount: 3, runtime: 90, highConfidenceCount: 1, sampleCount: 2)

        XCTAssertEqual(value(of: "Runtime", in: bar), "1.5m")
        XCTAssertEqual(value(of: "Samples", in: bar), "2")
    }

    /// A record that lists its samples hands the bar the run's own numbers.
    func testRecordedSamplesGiveTheirSummaryValues() {
        let sample = TaxTriageSample(
            sampleId: "S1", fastq1: URL(fileURLWithPath: "/nonexistent/S1.fastq.gz"), isNegativeControl: false
        )
        let config = TaxTriageConfig(samples: [sample], outputDirectory: folder)
        let result = TaxTriageResult(config: config, runtime: 12.5, exitCode: 0, outputDirectory: folder)

        XCTAssertEqual(TaxTriageProvenanceRows.summarySampleCount(result), 1)
        XCTAssertEqual(TaxTriageProvenanceRows.summaryRuntime(result), 12.5)
    }

    /// A record that lists no samples, and a result with no record at all, hand the bar nothing to show.
    func testNoSamplesAndNoSidecarGiveNoSummaryValues() {
        let config = TaxTriageConfig(samples: [], outputDirectory: folder)
        let empty = TaxTriageResult(config: config, runtime: 0, exitCode: 0, outputDirectory: folder)

        XCTAssertNil(TaxTriageProvenanceRows.summarySampleCount(empty))
        XCTAssertNil(TaxTriageProvenanceRows.summaryRuntime(empty))
        XCTAssertNil(TaxTriageProvenanceRows.summarySampleCount(nil), "a result with no sidecar must read Not recorded")
        XCTAssertNil(TaxTriageProvenanceRows.summaryRuntime(nil), "a result with no sidecar must read Not recorded")
    }

    private func value(of label: String, in bar: TaxTriageSummaryBar) -> String? {
        bar.cards.first { $0.label == label }?.value
    }
}
