// TaxTriageProvenanceNotRecordedTests.swift - The provenance popover of an import that does not record the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, UX-IMPORT-BATCH item 4 widened by BIO-IMPORT-BATCH
// item 4. An import whose record lists no samples cannot say how the run was set up, so the popover must not show
// the importer's defaults (Illumina, 0.0 seconds, confidence 0.20, top hits 10) as the run's.

import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishTaxTriageUI
@testable import LungfishWorkflow

@MainActor
final class TaxTriageProvenanceNotRecordedTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/nonexistent/taxtriage-provenance-view", isDirectory: true)

    /// With no samples recorded, every run setting reads Not recorded, and the counts of the folder stay.
    func testProvenanceViewReadsNotRecordedWithNoSamples() throws {
        let config = TaxTriageConfig(samples: [], outputDirectory: folder)
        let result = TaxTriageResult(config: config, runtime: 0, exitCode: 0, outputDirectory: folder)
        let texts = try shownTexts(result: result, config: config)

        for label in [
            "Samples", "Platform", "Runtime", "Exit Code", "Classifiers", "K2 Confidence", "Top Hits",
            "Skip Assembly", "Max CPUs", "Max Memory",
        ] {
            XCTAssertEqual(value(of: label, in: texts), "Not recorded", "\(label) shows a default as the run's: \(texts)")
        }
        XCTAssertEqual(value(of: "Reports", in: texts), "0")
        XCTAssertEqual(value(of: "Metrics Files", in: texts), "0")
        XCTAssertFalse(texts.contains { $0.contains("Illumina") || $0.contains("0.0 seconds") }, "\(texts)")
    }

    /// A run that records its samples keeps showing its own settings.
    func testProvenanceViewKeepsTheRunsSettingsWhenSamplesAreRecorded() throws {
        let sample = TaxTriageSample(
            sampleId: "S1", fastq1: URL(fileURLWithPath: "/nonexistent/S1.fastq.gz"), isNegativeControl: false
        )
        let config = TaxTriageConfig(samples: [sample], platform: .oxford, outputDirectory: folder)
        let result = TaxTriageResult(config: config, runtime: 12.5, exitCode: 0, outputDirectory: folder)
        let texts = try shownTexts(result: result, config: config)

        XCTAssertEqual(value(of: "Samples", in: texts), "1")
        XCTAssertEqual(value(of: "Platform", in: texts), "Oxford Nanopore")
        XCTAssertEqual(value(of: "Runtime", in: texts), "12.5 seconds")
        XCTAssertEqual(value(of: "Exit Code", in: texts), "0")
    }

    private func shownTexts(result: TaxTriageResult, config: TaxTriageConfig) throws -> [String] {
        try TaxTriageProvenanceView(result: result, config: config).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }
    }

    /// The text that follows `label` in the popover, whose rows are a label and a value.
    private func value(of label: String, in texts: [String]) -> String? {
        guard let index = texts.firstIndex(of: label), index + 1 < texts.count else { return nil }
        return texts[index + 1]
    }
}
