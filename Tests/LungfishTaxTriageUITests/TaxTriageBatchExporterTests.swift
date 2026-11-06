// TaxTriageBatchExporterTests.swift - Tests for batch export generation
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishTaxTriageUI
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

    /// Two sample names that the pipeline turns into one name leave a sample's rows out of a run with no control as well,
    /// so the report says it as the viewer's strip does (lane TTCONTROLS, BIO closing read, fix A).
    func testReportSaysWhenSampleNamesMeetAndTheRunListsNoControl() {
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "sample-1", fastq1: URL(fileURLWithPath: "/data/R1.fq")),
                TaxTriageSample(sampleId: "A (1)", fastq1: URL(fileURLWithPath: "/data/R2.fq")),
                TaxTriageSample(sampleId: "A_1", fastq1: URL(fileURLWithPath: "/data/R3.fq")),
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
            makeMetric(organism: "E. coli", sample: "sample-1", tassScore: 0.9),
            makeMetric(organism: "E. coli", sample: "A_1", tassScore: 0.85),
        ]

        let report = TaxTriageBatchExporter.generateSummaryReport(
            result: result,
            config: config,
            metrics: metrics,
            sampleIds: ["sample-1", "A_1"]
        )

        XCTAssertTrue(
            report.contains("A (1) and A_1 are both named A_1 in the results, and the results hold only one sample"),
            "the run lists no control, but the report said nothing of the names that meet: \(report)"
        )
        XCTAssertFalse(report.contains("Negative Controls:"), report)
    }

    // MARK: - A control that was not fully checked reads Not checked (3.2 TTNOTCHECKED)
    //
    // Rows TAXTRIAGE-CONTROL-PARTIAL-RESULT and TAXTRIAGE-SAMPLE-NAMES-OLD-RESULT (BIO S2-R1 section 1). A control that
    // has rows but lost a step the pipeline skipped, or whose name became the name of another control, is read from the
    // rows it has. What it lists stays Yes, and a No for an organism it does not list is not known, so the matrix and the
    // results table say Not checked there. The tests run the loader that the CLI exports use, on a saved result.

    private static let alpha = "Alpha virus"
    private static let beta = "Beta virus"

    func testMatrixSaysNotCheckedForAFoundControlWithASkippedStep() throws {
        let root = try makeNotCheckedResult(
            listed: [("NTC", true), ("P1", false)],
            rows: [("NTC", Self.alpha), ("P1", Self.alpha), ("P1", Self.beta)],
            ignored: [try Self.parsedEntry(process: "MINIMAP2_ALIGN", tag: "NTC")]
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)

        let risk = Self.matrixRisk(of: source)
        XCTAssertEqual(risk[Self.alpha], "Yes", "the control holds it: \(risk)")
        XCTAssertEqual(risk[Self.beta], "Not checked", "a step of the control was skipped, so its No is not known: \(risk)")
    }

    func testMatrixSaysNotCheckedWhenTwoControlNamesBecameOne() throws {
        let root = try makeNotCheckedResult(
            listed: [("NTC 1", true), ("NTC_1", true), ("P1", false)],
            rows: [("NTC_1", Self.alpha), ("P1", Self.alpha), ("P1", Self.beta)]
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)

        let risk = Self.matrixRisk(of: source)
        XCTAssertEqual(risk[Self.alpha], "Yes", "the kept control holds it: \(risk)")
        XCTAssertEqual(risk[Self.beta], "Not checked", "the control left out may have held it: \(risk)")
    }

    func testResultsExportSaysNotCheckedForAFoundControlWithASkippedStep() throws {
        let root = try makeNotCheckedResult(
            listed: [("NTC", true), ("P1", false)],
            rows: [("NTC", Self.alpha), ("P1", Self.alpha), ("P1", Self.beta)],
            ignored: [try Self.parsedEntry(process: "MINIMAP2_ALIGN", tag: "NTC")]
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)

        let risk = Self.resultsRisk(of: source)
        XCTAssertEqual(risk["P1/\(Self.alpha)"], "yes", "the control holds it: \(risk)")
        XCTAssertEqual(risk["P1/\(Self.beta)"], "Not checked", "the cell was blank for a No that is not known: \(risk)")
    }

    func testResultsExportSaysNotCheckedWhenTwoControlNamesBecameOne() throws {
        let root = try makeNotCheckedResult(
            listed: [("NTC 1", true), ("NTC_1", true), ("P1", false)],
            rows: [("NTC_1", Self.alpha), ("P1", Self.alpha), ("P1", Self.beta)]
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)

        let risk = Self.resultsRisk(of: source)
        XCTAssertEqual(risk["P1/\(Self.alpha)"], "yes", "the kept control holds it: \(risk)")
        XCTAssertEqual(risk["P1/\(Self.beta)"], "Not checked", "the control left out may have held it: \(risk)")
    }

    // MARK: - The ignored entries that must not make a control Not checked (green at the base and after)

    /// FASTQC only draws quality plots, so a control whose plot step failed and that has rows still reads No.
    func testMatrixKeepsNoForAFoundControlWhoseOnlyEntryDrawsQualityPlots() throws {
        let root = try makeNotCheckedResult(
            listed: [("NTC", true), ("P1", false)],
            rows: [("NTC", Self.alpha), ("P1", Self.alpha), ("P1", Self.beta)],
            ignored: [try Self.parsedEntry(process: "FASTQC", tag: "NTC")]
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)

        let risk = Self.matrixRisk(of: source)
        XCTAssertEqual(risk[Self.alpha], "Yes", "\(risk)")
        XCTAssertEqual(risk[Self.beta], "No", "a quality plot costs the control no organism: \(risk)")
    }

    /// The routine empty-reference entry of ALIGNMENT_PER_SAMPLE is dropped by `sanitizeIgnoredFailures` before the run is
    /// saved (`MetagenomicsImportService.importTaxTriage` and `TaxTriageResult.detectErroredProcesses` both call it), so
    /// the sidecar never holds it and a control with rows keeps reading No.
    func testMatrixKeepsNoForAFoundControlOnceTheRoutineAlignmentEntryIsFiltered() throws {
        let root = try makeNotCheckedRoot()
        for directory in ["map", "combine", "download"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true
            )
        }
        try "Acc\tAssembly\tOrganism_Name\tDescription\tMapped_Value\n".write(
            to: root.appendingPathComponent("map/NTC.merged.taxid.tsv"), atomically: true, encoding: .utf8
        )
        try Data().write(to: root.appendingPathComponent("combine/NTC.combined.gcfmap.tsv"))
        try Data().write(to: root.appendingPathComponent("download/NTC.dwnld.references.fasta"))
        let routine = try Self.parsedEntry(process: "ALIGNMENT_PER_SAMPLE", tag: "NTC")
        let stored = TaxTriageResult.sanitizeIgnoredFailures([routine], outputDirectory: root)
        XCTAssertTrue(stored.isEmpty, "the routine entry reached the sidecar: \(stored)")
        try writeNotCheckedResult(
            in: root,
            listed: [("NTC", true), ("P1", false)],
            rows: [("NTC", Self.alpha), ("P1", Self.alpha), ("P1", Self.beta)],
            ignored: stored
        )
        let source = try TaxTriageExportLoader.load(resultURL: root, samples: [], searchText: nil)

        let risk = Self.matrixRisk(of: source)
        XCTAssertEqual(risk[Self.beta], "No", "\(risk)")
    }

    // MARK: - Helpers for the Not checked cells

    private func makeNotCheckedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageNotChecked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A saved result in a new folder. `rows` are (sample, organism) pairs of its database, `listed` the samples as typed
    /// with their control mark, and `ignored` the tasks Nextflow ignored an error in.
    private func makeNotCheckedResult(
        listed: [(String, Bool)],
        rows: [(String, String)],
        ignored: [TaxTriageIgnoredFailure] = []
    ) throws -> URL {
        let root = try makeNotCheckedRoot()
        try writeNotCheckedResult(in: root, listed: listed, rows: rows, ignored: ignored)
        return root
    }

    private func writeNotCheckedResult(
        in root: URL,
        listed: [(String, Bool)],
        rows: [(String, String)],
        ignored: [TaxTriageIgnoredFailure]
    ) throws {
        _ = try TaxTriageDatabase.create(
            at: root.appendingPathComponent(TaxTriageExportLoader.databaseFileName),
            rows: rows.map { Self.databaseRow(sample: $0.0, organism: $0.1) },
            metadata: ["tool": "taxtriage"]
        )
        let config = TaxTriageConfig(
            samples: listed.map {
                TaxTriageSample(
                    sampleId: $0.0,
                    fastq1: root.appendingPathComponent("\($0.0).fastq.gz"),
                    isNegativeControl: $0.1
                )
            },
            outputDirectory: root
        )
        try TaxTriageResult(
            config: config, runtime: 61, exitCode: 0, outputDirectory: root, ignoredFailures: ignored
        ).save()
    }

    /// The entry that the parser writes for the pipeline's note about a task of `tag`, which holds the bare tag as its
    /// task label (`TaxTriageResult.parseIgnoredFailures`).
    private static func parsedEntry(process: String, tag: String) throws -> TaxTriageIgnoredFailure {
        let note = "NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:\(process) (\(tag))` terminated with an error exit status (137) -- Error is ignored"
        return try XCTUnwrap(TaxTriageResult.parseIgnoredFailures(fromNextflowLogText: note).first, note)
    }

    /// The Contamination Risk cell of each organism row, as `taxtriage export organism-matrix` builds the matrix.
    private static func matrixRisk(of source: TaxTriageExportSource) -> [String: String] {
        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: source.metrics,
            sampleIds: source.sampleIds,
            negativeControlSampleIds: source.controlMatch.controlSampleIds,
            controlMetrics: source.controlMetrics,
            controlsNotRecorded: source.controlsNotRecorded,
            controlsNotChecked: source.controlsNotChecked
        )
        var risk: [String: String] = [:]
        for line in csv.split(separator: "\n").dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            risk[cells[0]] = cells[3]
        }
        return risk
    }

    /// The Contamination Risk cell of each row of `taxtriage export results`, keyed `sample/organism`.
    private static func resultsRisk(of source: TaxTriageExportSource) -> [String: String] {
        let text = TaxTriageResultsExport.buildDelimitedExport(
            rows: source.metrics,
            totalReadsByKey: source.totalReadsByKey,
            uniqueReadsByKey: source.uniqueReadsByKey,
            contaminationRiskOrganismKeys: source.contaminationRiskOrganismKeys,
            controlsNotRecorded: source.controlsNotRecorded,
            controlsNotChecked: source.controlsNotChecked,
            metadataHeaders: [],
            metadataValuesBySample: [:],
            separator: "\t"
        )
        var risk: [String: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            risk["\(cells[0])/\(cells[1])"] = cells.last
        }
        return risk
    }

    private static func databaseRow(sample: String, organism: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: organism == alpha ? 1001 : 1002, status: nil, tassScore: 0.9,
            readsAligned: 40, uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50,
            meanCoverage: nil, meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil,
            giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil,
            minhashScore: nil, diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil,
            breadthWeightScore: nil, hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil,
            highConsequence: nil, isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: "\(sample)/minimap2/\(sample).bam", bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
            primaryAccession: "NC_\(organism == alpha ? 1001 : 1002)", accessionLength: 10_000
        )
    }
}
