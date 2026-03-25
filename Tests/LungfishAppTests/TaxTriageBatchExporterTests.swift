// TaxTriageBatchExporterTests.swift - Tests for batch export generation
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageBatchExporterTests: XCTestCase {

    private func makeMetric(
        organism: String,
        sample: String,
        tassScore: Double,
        reads: Int = 100
    ) -> TaxTriageMetric {
        TaxTriageMetric(
            sample: sample,
            organism: organism,
            rank: "S",
            reads: reads,
            abundance: 0.1,
            coverageBreadth: 50.0,
            coverageDepth: 10.0,
            tassScore: tassScore,
            confidence: "High"
        )
    }

    func testOrganismMatrixCSVHeaders() {
        let metrics = [
            makeMetric(organism: "E. coli", sample: "S1", tassScore: 0.9),
            makeMetric(organism: "E. coli", sample: "S2", tassScore: 0.7),
        ]

        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: metrics,
            sampleIds: ["S1", "S2"]
        )

        let lines = csv.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].contains("Organism"))
        XCTAssertTrue(lines[0].contains("Mean TASS"))
        XCTAssertTrue(lines[0].contains("S1"))
        XCTAssertTrue(lines[0].contains("S2"))
        XCTAssertTrue(lines[0].contains("Contamination Risk"))
    }

    func testOrganismMatrixCSVData() {
        let metrics = [
            makeMetric(organism: "E. coli", sample: "S1", tassScore: 0.9),
            makeMetric(organism: "E. coli", sample: "S2", tassScore: 0.7),
            makeMetric(organism: "SARS-CoV-2", sample: "S1", tassScore: 0.3),
        ]

        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: metrics,
            sampleIds: ["S1", "S2"]
        )

        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Header + 2 organisms
        XCTAssertEqual(lines.count, 3)
        // E. coli should appear first (2 samples)
        XCTAssertTrue(lines[1].hasPrefix("E. coli"))
    }

    func testContaminationRiskInCSV() {
        let metrics = [
            makeMetric(organism: "E. coli", sample: "S1", tassScore: 0.9),
            makeMetric(organism: "E. coli", sample: "NTC", tassScore: 0.2),
        ]

        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: metrics,
            sampleIds: ["S1", "NTC"],
            negativeControlSampleIds: ["NTC"]
        )

        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertTrue(lines[1].contains("Yes"))
    }

    func testSummaryReportContainsSections() {
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/R1.fq")),
                TaxTriageSample(sampleId: "S2", fastq1: URL(fileURLWithPath: "/data/R2.fq")),
            ],
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 120.5,
            exitCode: 0,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        let metrics = [
            makeMetric(organism: "E. coli", sample: "S1", tassScore: 0.9),
            makeMetric(organism: "E. coli", sample: "S2", tassScore: 0.85),
        ]

        let report = TaxTriageBatchExporter.generateSummaryReport(
            result: result,
            config: config,
            metrics: metrics,
            sampleIds: ["S1", "S2"]
        )

        XCTAssertTrue(report.contains("TaxTriage Batch Analysis Report"))
        XCTAssertTrue(report.contains("Samples: 2"))
        XCTAssertTrue(report.contains("Per-Sample Summary"))
        XCTAssertTrue(report.contains("Cross-Sample Organisms"))
        XCTAssertTrue(report.contains("High-Confidence Organisms"))
        XCTAssertTrue(report.contains("E. coli"))
    }
}
