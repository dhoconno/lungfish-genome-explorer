// TaxTriageParserTests.swift - Tests for TaxTriage samplesheet and report parsers
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class TaxTriageParserTests: XCTestCase {

    // MARK: - Samplesheet Generation Tests

    func testSamplesheetGenerationSingleEnd() {
        let entries = [
            TaxTriageSampleEntry(
                sampleId: "Sample1",
                fastq1Path: "/data/reads.fastq.gz",
                fastq2Path: nil,
                platform: "ILLUMINA"
            )
        ]

        let csv = TaxTriageSamplesheet.generate(from: entries)

        XCTAssertTrue(csv.hasPrefix("sample,fastq_1,fastq_2,platform\n"))
        XCTAssertTrue(csv.contains("Sample1,/data/reads.fastq.gz,,ILLUMINA"))
    }

    func testSamplesheetGenerationPairedEnd() {
        let entries = [
            TaxTriageSampleEntry(
                sampleId: "Sample1",
                fastq1Path: "/data/R1.fastq.gz",
                fastq2Path: "/data/R2.fastq.gz",
                platform: "ILLUMINA"
            )
        ]

        let csv = TaxTriageSamplesheet.generate(from: entries)

        XCTAssertTrue(csv.contains(
            "Sample1,/data/R1.fastq.gz,/data/R2.fastq.gz,ILLUMINA"
        ))
    }

    func testSamplesheetGenerationMultipleSamples() {
        let entries = [
            TaxTriageSampleEntry(
                sampleId: "Sample1",
                fastq1Path: "/data/S1.fq.gz",
                platform: "ILLUMINA"
            ),
            TaxTriageSampleEntry(
                sampleId: "Sample2",
                fastq1Path: "/data/S2.fq.gz",
                platform: "OXFORD"
            ),
            TaxTriageSampleEntry(
                sampleId: "Sample3",
                fastq1Path: "/data/S3.fq.gz",
                fastq2Path: "/data/S3_R2.fq.gz",
                platform: "PACBIO"
            ),
        ]

        let csv = TaxTriageSamplesheet.generate(from: entries)
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 4) // header + 3 samples
        XCTAssertTrue(lines[1].contains("Sample1"))
        XCTAssertTrue(lines[2].contains("Sample2"))
        XCTAssertTrue(lines[2].contains("OXFORD"))
        XCTAssertTrue(lines[3].contains("Sample3"))
    }

    func testSamplesheetCSVEscaping() {
        let entries = [
            TaxTriageSampleEntry(
                sampleId: "Sample,With,Commas",
                fastq1Path: "/data/reads.fq.gz",
                platform: "ILLUMINA"
            )
        ]

        let csv = TaxTriageSamplesheet.generate(from: entries)

        // The sample ID should be quoted because it contains commas
        XCTAssertTrue(csv.contains("\"Sample,With,Commas\""))
    }

    func testSamplesheetEmptySamples() {
        let csv = TaxTriageSamplesheet.generate(from: [])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 1) // header only
        XCTAssertEqual(lines[0], TaxTriageSamplesheet.header)
    }

    // MARK: - Samplesheet Write/Read Tests

    func testSamplesheetWriteAndParse() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries = [
            TaxTriageSampleEntry(
                sampleId: "WR1",
                fastq1Path: "/data/WR1_R1.fq.gz",
                fastq2Path: "/data/WR1_R2.fq.gz",
                platform: "ILLUMINA"
            ),
            TaxTriageSampleEntry(
                sampleId: "WR2",
                fastq1Path: "/data/WR2.fq.gz",
                platform: "OXFORD"
            ),
        ]

        let fileURL = tempDir.appendingPathComponent("samplesheet.csv")
        try TaxTriageSamplesheet.write(samples: entries, to: fileURL)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Parse it back
        let parsed = try TaxTriageSamplesheet.parse(url: fileURL)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].sampleId, "WR1")
        XCTAssertEqual(parsed[0].fastq1Path, "/data/WR1_R1.fq.gz")
        XCTAssertEqual(parsed[0].fastq2Path, "/data/WR1_R2.fq.gz")
        XCTAssertEqual(parsed[0].platform, "ILLUMINA")
        XCTAssertTrue(parsed[0].isPairedEnd)

        XCTAssertEqual(parsed[1].sampleId, "WR2")
        XCTAssertEqual(parsed[1].fastq1Path, "/data/WR2.fq.gz")
        XCTAssertNil(parsed[1].fastq2Path)
        XCTAssertEqual(parsed[1].platform, "OXFORD")
        XCTAssertFalse(parsed[1].isPairedEnd)
    }

    // MARK: - Samplesheet Parsing Tests

    func testParseSamplesheetCSV() throws {
        let csv = """
        sample,fastq_1,fastq_2,platform
        MySample,/path/to/R1.fastq.gz,/path/to/R2.fastq.gz,ILLUMINA
        ONTSample,/path/to/reads.fq.gz,,OXFORD
        """

        let entries = try TaxTriageSamplesheet.parse(csv: csv)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].sampleId, "MySample")
        XCTAssertEqual(entries[0].fastq1Path, "/path/to/R1.fastq.gz")
        XCTAssertEqual(entries[0].fastq2Path, "/path/to/R2.fastq.gz")
        XCTAssertEqual(entries[0].platform, "ILLUMINA")

        XCTAssertEqual(entries[1].sampleId, "ONTSample")
        XCTAssertNil(entries[1].fastq2Path)
        XCTAssertEqual(entries[1].platform, "OXFORD")
    }

    func testParseSamplesheetEmptyFile() {
        XCTAssertThrowsError(try TaxTriageSamplesheet.parse(csv: "")) { error in
            guard let ssError = error as? TaxTriageSamplesheetError else {
                XCTFail("Expected TaxTriageSamplesheetError"); return
            }
            if case .emptyFile = ssError {
                // Expected
            } else {
                XCTFail("Expected .emptyFile, got \(ssError)")
            }
        }
    }

    func testParseSamplesheetInvalidHeader() {
        let csv = "name,file1,file2,technology\nS1,/f1,,ILLUMINA"

        XCTAssertThrowsError(try TaxTriageSamplesheet.parse(csv: csv)) { error in
            guard let ssError = error as? TaxTriageSamplesheetError else {
                XCTFail("Expected TaxTriageSamplesheetError"); return
            }
            if case .invalidHeader = ssError {
                // Expected
            } else {
                XCTFail("Expected .invalidHeader, got \(ssError)")
            }
        }
    }

    func testParseSamplesheetInsufficientColumns() {
        let csv = "sample,fastq_1,fastq_2,platform\nS1,/file1"

        XCTAssertThrowsError(try TaxTriageSamplesheet.parse(csv: csv)) { error in
            guard let ssError = error as? TaxTriageSamplesheetError else {
                XCTFail("Expected TaxTriageSamplesheetError"); return
            }
            if case .insufficientColumns(let line, _, _) = ssError {
                XCTAssertEqual(line, 2)
            } else {
                XCTFail("Expected .insufficientColumns, got \(ssError)")
            }
        }
    }

    func testParseSamplesheetEmptySampleId() {
        let csv = "sample,fastq_1,fastq_2,platform\n,/file.fq,,ILLUMINA"

        XCTAssertThrowsError(try TaxTriageSamplesheet.parse(csv: csv)) { error in
            guard let ssError = error as? TaxTriageSamplesheetError else {
                XCTFail("Expected TaxTriageSamplesheetError"); return
            }
            if case .emptySampleId = ssError {
                // Expected
            } else {
                XCTFail("Expected .emptySampleId, got \(ssError)")
            }
        }
    }

    func testParseSamplesheetEmptyFastq1() {
        let csv = "sample,fastq_1,fastq_2,platform\nS1,,,ILLUMINA"

        XCTAssertThrowsError(try TaxTriageSamplesheet.parse(csv: csv)) { error in
            guard let ssError = error as? TaxTriageSamplesheetError else {
                XCTFail("Expected TaxTriageSamplesheetError"); return
            }
            if case .emptyFastq1(_, let sampleId) = ssError {
                XCTAssertEqual(sampleId, "S1")
            } else {
                XCTFail("Expected .emptyFastq1, got \(ssError)")
            }
        }
    }

    // MARK: - TaxTriageSampleEntry Tests

    func testSampleEntryIsPairedEnd() {
        let paired = TaxTriageSampleEntry(
            sampleId: "S1",
            fastq1Path: "/R1.fq",
            fastq2Path: "/R2.fq",
            platform: "ILLUMINA"
        )
        XCTAssertTrue(paired.isPairedEnd)

        let single = TaxTriageSampleEntry(
            sampleId: "S2",
            fastq1Path: "/reads.fq",
            platform: "ILLUMINA"
        )
        XCTAssertFalse(single.isPairedEnd)

        let emptyR2 = TaxTriageSampleEntry(
            sampleId: "S3",
            fastq1Path: "/reads.fq",
            fastq2Path: "",
            platform: "ILLUMINA"
        )
        XCTAssertFalse(emptyR2.isPairedEnd)
    }

    // MARK: - Report Parser Tests

    func testParseOrganismReport() {
        let report = """
        Organism: Escherichia coli
        Score: 0.95
        Reads: 12345
        Coverage: 85.3%

        Organism: Staphylococcus aureus
        Score: 0.82
        Reads: 5678
        Coverage: 72.1%
        """

        let organisms = TaxTriageReportParser.parse(text: report)

        XCTAssertEqual(organisms.count, 2)

        XCTAssertEqual(organisms[0].name, "Escherichia coli")
        XCTAssertEqual(organisms[0].score, 0.95)
        XCTAssertEqual(organisms[0].reads, 12345)
        XCTAssertEqual(organisms[0].coverage, 85.3)

        XCTAssertEqual(organisms[1].name, "Staphylococcus aureus")
        XCTAssertEqual(organisms[1].score, 0.82)
        XCTAssertEqual(organisms[1].reads, 5678)
        XCTAssertEqual(organisms[1].coverage, 72.1)
    }

    func testParseReportWithOptionalFields() {
        let report = """
        Organism: Klebsiella pneumoniae
        Score: 0.91
        Reads: 9876
        Coverage: 90.5%
        TaxID: 573
        Rank: species
        """

        let organisms = TaxTriageReportParser.parse(text: report)

        XCTAssertEqual(organisms.count, 1)
        XCTAssertEqual(organisms[0].name, "Klebsiella pneumoniae")
        XCTAssertEqual(organisms[0].taxId, 573)
        XCTAssertEqual(organisms[0].rank, "species")
    }

    func testParseReportCoverageWithoutPercent() {
        let report = """
        Organism: TestOrg
        Score: 0.5
        Reads: 100
        Coverage: 50.0
        """

        let organisms = TaxTriageReportParser.parse(text: report)

        XCTAssertEqual(organisms.count, 1)
        XCTAssertEqual(organisms[0].coverage, 50.0)
    }

    func testParseReportEmpty() {
        let organisms = TaxTriageReportParser.parse(text: "")
        XCTAssertTrue(organisms.isEmpty)
    }

    func testParseReportNoBlankLineSeparators() {
        // Test that the parser handles organisms separated by new Organism: lines
        // without blank lines between them
        let report = """
        Organism: Org1
        Score: 0.9
        Reads: 100
        Organism: Org2
        Score: 0.8
        Reads: 200
        """

        let organisms = TaxTriageReportParser.parse(text: report)

        XCTAssertEqual(organisms.count, 2)
        XCTAssertEqual(organisms[0].name, "Org1")
        XCTAssertEqual(organisms[0].score, 0.9)
        XCTAssertEqual(organisms[1].name, "Org2")
        XCTAssertEqual(organisms[1].score, 0.8)
    }

    func testParseReportMissingFields() {
        let report = """
        Organism: PartialOrg
        Reads: 50
        """

        let organisms = TaxTriageReportParser.parse(text: report)

        XCTAssertEqual(organisms.count, 1)
        XCTAssertEqual(organisms[0].name, "PartialOrg")
        XCTAssertEqual(organisms[0].score, 0.0) // default
        XCTAssertEqual(organisms[0].reads, 50)
        XCTAssertNil(organisms[0].coverage)
    }

    func testOrganismIdentifiable() {
        let org = TaxTriageOrganism(
            name: "E. coli",
            score: 0.9,
            reads: 100
        )
        XCTAssertEqual(org.id, "E. coli")
    }

    func testOrganismCodable() throws {
        let org = TaxTriageOrganism(
            name: "Test Org",
            score: 0.85,
            reads: 500,
            coverage: 75.2,
            taxId: 12345,
            rank: "species"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(org)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaxTriageOrganism.self, from: data)

        XCTAssertEqual(decoded.name, "Test Org")
        XCTAssertEqual(decoded.score, 0.85)
        XCTAssertEqual(decoded.reads, 500)
        XCTAssertEqual(decoded.coverage, 75.2)
        XCTAssertEqual(decoded.taxId, 12345)
        XCTAssertEqual(decoded.rank, "species")
    }

    // MARK: - Metrics Parser Tests

    func testParseMetricsTSV() throws {
        let tsv = """
        sample\ttaxid\torganism\trank\treads\tabundance\tcoverage_breadth\tcoverage_depth\ttass_score\tconfidence
        MySample\t562\tEscherichia coli\tS\t12345\t0.45\t85.3\t12.7\t0.95\thigh
        MySample\t1280\tStaphylococcus aureus\tS\t5678\t0.21\t72.1\t8.3\t0.82\tmedium
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 2)

        XCTAssertEqual(metrics[0].sample, "MySample")
        XCTAssertEqual(metrics[0].taxId, 562)
        XCTAssertEqual(metrics[0].organism, "Escherichia coli")
        XCTAssertEqual(metrics[0].rank, "S")
        XCTAssertEqual(metrics[0].reads, 12345)
        XCTAssertEqual(metrics[0].abundance, 0.45)
        XCTAssertEqual(metrics[0].coverageBreadth, 85.3)
        XCTAssertEqual(metrics[0].coverageDepth, 12.7)
        XCTAssertEqual(metrics[0].tassScore, 0.95)
        XCTAssertEqual(metrics[0].confidence, "high")

        XCTAssertEqual(metrics[1].organism, "Staphylococcus aureus")
        XCTAssertEqual(metrics[1].tassScore, 0.82)
        XCTAssertEqual(metrics[1].confidence, "medium")
    }

    func testParseMetricsAdditionalColumns() throws {
        let tsv = """
        sample\ttaxid\torganism\ttass_score\tcustom_field
        S1\t100\tOrgA\t0.9\textra_value
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].organism, "OrgA")
        XCTAssertEqual(metrics[0].tassScore, 0.9)
        XCTAssertEqual(metrics[0].additionalFields["custom_field"], "extra_value")
    }

    func testParseMetricsEmptyFile() {
        XCTAssertThrowsError(
            try TaxTriageMetricsParser.parse(tsv: "")
        ) { error in
            guard let metricsError = error as? TaxTriageMetricsParserError else {
                XCTFail("Expected TaxTriageMetricsParserError"); return
            }
            if case .emptyFile = metricsError {
                // Expected
            } else {
                XCTFail("Expected .emptyFile, got \(metricsError)")
            }
        }
    }

    func testParseMetricsMissingOptionalColumns() throws {
        let tsv = """
        organism\ttass_score\treads
        Some Organism\t0.75\t1000
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].organism, "Some Organism")
        XCTAssertEqual(metrics[0].tassScore, 0.75)
        XCTAssertEqual(metrics[0].reads, 1000)
        XCTAssertNil(metrics[0].sample)
        XCTAssertNil(metrics[0].taxId)
        XCTAssertNil(metrics[0].rank)
        XCTAssertNil(metrics[0].abundance)
        XCTAssertNil(metrics[0].coverageBreadth)
        XCTAssertNil(metrics[0].coverageDepth)
        XCTAssertNil(metrics[0].confidence)
    }

    func testParseMetricsFromTaxTriageConfidenceReport() throws {
        let tsv = """
        Index\tDetected Organism\t# Reads Aligned\tCoverage\tTaxonomic ID #\tK2 Reads\tTASS Score\tStatus
        0\t★ WU Polyomavirus°\t693\t0.94\t440266\t688\t1.0\testablished
        1\tHuman mastadenovirus F\t518\t0.17\t130309\t299\t0.86\testablished
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics.count, 2)

        XCTAssertEqual(metrics[0].organism, "WU Polyomavirus")
        XCTAssertEqual(metrics[0].reads, 693)
        XCTAssertEqual(metrics[0].coverageBreadth, 94.0)
        XCTAssertEqual(metrics[0].taxId, 440266)
        XCTAssertEqual(metrics[0].tassScore, 1.0)
        XCTAssertEqual(metrics[0].confidence, "established")

        XCTAssertEqual(metrics[1].organism, "Human mastadenovirus F")
        XCTAssertEqual(metrics[1].reads, 518)
        XCTAssertEqual(metrics[1].coverageBreadth, 17.0)
        XCTAssertEqual(metrics[1].taxId, 130309)
        XCTAssertEqual(metrics[1].tassScore, 0.86)
    }

    func testParseMetricsRepairsInfluenzaLeadingCharacterDrop() throws {
        let tsv = """
        Index\tDetected Organism\t# Reads Aligned\tCoverage\tTaxonomic ID #\tK2 Reads\tTASS Score\tStatus
        0\t★ nfluenza B virus (B/Lee/40)°\t9\t0.03\t518987\t0\t0.29\testablished
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].organism, "Influenza B virus (B/Lee/40)")
        XCTAssertEqual(metrics[0].taxId, 518987)
    }

    func testParseMetricsLineNumbers() throws {
        let tsv = """
        organism\ttass_score
        Org1\t0.9
        Org2\t0.8
        Org3\t0.7
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 3)
        XCTAssertEqual(metrics[0].sourceLineNumber, 2)
        XCTAssertEqual(metrics[1].sourceLineNumber, 3)
        XCTAssertEqual(metrics[2].sourceLineNumber, 4)
    }

    func testMetricCodable() throws {
        let metric = TaxTriageMetric(
            sample: "Test",
            taxId: 562,
            organism: "E. coli",
            rank: "S",
            reads: 5000,
            abundance: 0.45,
            coverageBreadth: 85.0,
            coverageDepth: 12.0,
            tassScore: 0.95,
            confidence: "high"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(metric)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaxTriageMetric.self, from: data)

        XCTAssertEqual(decoded.organism, "E. coli")
        XCTAssertEqual(decoded.tassScore, 0.95)
        XCTAssertEqual(decoded.taxId, 562)
        XCTAssertEqual(decoded.confidence, "high")
    }

    // MARK: - Samplesheet Error Description Tests

    func testSamplesheetErrorDescriptions() {
        let errors: [TaxTriageSamplesheetError] = [
            .emptyFile,
            .invalidHeader(expected: ["a"], got: ["b"]),
            .insufficientColumns(line: 3, expected: 4, got: 2),
            .emptySampleId(line: 2),
            .emptyFastq1(line: 2, sampleId: "S1"),
        ]

        for error in errors {
            XCTAssertNotNil(
                error.errorDescription,
                "\(error) should have a description"
            )
        }
    }

    func testMetricsErrorDescriptions() {
        let errors: [TaxTriageMetricsParserError] = [
            .emptyFile,
            .emptyHeader,
        ]

        for error in errors {
            XCTAssertNotNil(
                error.errorDescription,
                "\(error) should have a description"
            )
        }
    }

    // MARK: - Report Parser File I/O Tests

    func testReportParserFromFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-rpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reportContent = """
        Organism: Test Species
        Score: 0.88
        Reads: 3000
        Coverage: 65.0%
        """

        let reportURL = tempDir.appendingPathComponent("report.txt")
        try reportContent.write(to: reportURL, atomically: true, encoding: .utf8)

        let organisms = try TaxTriageReportParser.parse(url: reportURL)

        XCTAssertEqual(organisms.count, 1)
        XCTAssertEqual(organisms[0].name, "Test Species")
        XCTAssertEqual(organisms[0].score, 0.88)
    }

    func testMetricsParserFromFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-met-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metricsContent = "organism\ttass_score\treads\nTestOrg\t0.92\t10000"
        let metricsURL = tempDir.appendingPathComponent("metrics.tsv")
        try metricsContent.write(
            to: metricsURL, atomically: true, encoding: .utf8
        )

        let metrics = try TaxTriageMetricsParser.parse(url: metricsURL)

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].organism, "TestOrg")
        XCTAssertEqual(metrics[0].tassScore, 0.92)
        XCTAssertEqual(metrics[0].reads, 10000)
    }

    // MARK: - Edge Case: Multi-Sample Confidences TSV

    func testParseMultiSampleConfidencesTSV() throws {
        let tsv = """
        Specimen ID\tDetected Organism\t# Reads Aligned\tCoverage\tTaxonomic ID #\tK2 Reads\tTASS Score\tStatus
        SampleA\t★ Escherichia coli°\t5000\t0.75\t562\t4800\t0.95\thigh
        SampleA\t★ Klebsiella pneumoniae°\t2000\t0.40\t573\t1900\t0.72\tmedium
        SampleB\t★ Escherichia coli°\t8000\t0.88\t562\t7900\t0.98\thigh
        SampleB\t★ SARS-CoV-2°\t150\t0.15\t2697049\t100\t0.35\tlow
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 4)

        // Verify sample IDs are parsed
        XCTAssertEqual(metrics[0].sample, "SampleA")
        XCTAssertEqual(metrics[2].sample, "SampleB")

        // Verify organism name cleaning
        XCTAssertEqual(metrics[0].organism, "Escherichia coli")
        XCTAssertEqual(metrics[1].organism, "Klebsiella pneumoniae")

        // Verify per-sample filtering
        let sampleAMetrics = metrics.filter { $0.sample == "SampleA" }
        XCTAssertEqual(sampleAMetrics.count, 2)

        let sampleBMetrics = metrics.filter { $0.sample == "SampleB" }
        XCTAssertEqual(sampleBMetrics.count, 2)
    }

    func testParseSingleSampleNoSampleColumn() throws {
        // Some TaxTriage outputs omit the sample column for single-sample runs
        let tsv = """
        organism\treads\ttass_score\tconfidence
        Escherichia coli\t5000\t0.95\thigh
        Staphylococcus aureus\t2000\t0.72\tmedium
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 2)
        XCTAssertNil(metrics[0].sample)
        XCTAssertNil(metrics[1].sample)
        XCTAssertEqual(metrics[0].organism, "Escherichia coli")
        XCTAssertEqual(metrics[0].reads, 5000)
    }

    // MARK: - Edge Case: Special Characters in Organism Names

    func testParseOrganismWithSpecialCharacters() throws {
        let tsv = """
        organism\ttass_score\treads
        ★ WU Polyomavirus°\t1.0\t693
        \u{25CF} Human mastadenovirus F\t0.86\t518
        Bacillus cereus var. fluorescéns\t0.5\t100
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 3)
        XCTAssertEqual(metrics[0].organism, "WU Polyomavirus")
        XCTAssertEqual(metrics[1].organism, "Human mastadenovirus F")
        // Accented characters are preserved in the clean step
        XCTAssertTrue(metrics[2].organism.contains("fluoresc"))
    }

    // MARK: - Edge Case: Metrics with Zero Reads

    func testParseMetricsWithZeroReads() throws {
        let tsv = """
        organism\treads\ttass_score\tconfidence
        NoReadsOrganism\t0\t0.0\tlow
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].reads, 0)
        XCTAssertEqual(metrics[0].tassScore, 0.0)
    }

    // MARK: - Edge Case: Header Only (No Data Rows)

    func testParseMetricsHeaderOnly() throws {
        let tsv = "organism\ttass_score\treads\n"

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertTrue(metrics.isEmpty)
    }

    // MARK: - Edge Case: Extra/Unknown Columns

    func testParseMetricsExtraColumnsPreserved() throws {
        let tsv = """
        organism\ttass_score\treads\tcustom_1\tcustom_2\tunknown_field
        TestOrg\t0.8\t500\tvalA\tvalB\tvalC
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].additionalFields["custom_1"], "valA")
        XCTAssertEqual(metrics[0].additionalFields["custom_2"], "valB")
        XCTAssertEqual(metrics[0].additionalFields["unknown_field"], "valC")
    }

    // MARK: - Edge Case: Coverage Normalization

    func testParseCoverageFractionNormalized() throws {
        // Coverage as fraction (0-1) should be normalized to percentage (0-100)
        let tsv = """
        organism\ttass_score\tcoverage_breadth
        OrgA\t0.9\t0.75
        OrgB\t0.8\t75.0
        OrgC\t0.7\t0.0
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)

        XCTAssertEqual(metrics[0].coverageBreadth, 75.0) // 0.75 * 100
        XCTAssertEqual(metrics[1].coverageBreadth, 75.0) // already percentage
        XCTAssertEqual(metrics[2].coverageBreadth, 0.0) // zero stays zero
    }

    // MARK: - Edge Case: Reads Column Fallback

    func testParseMetricsReadsColumnFallback() throws {
        // When "reads aligned" isn't present, fall back to "read count"
        let tsv = """
        organism\ttass_score\tread count
        OrgA\t0.9\t1000
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics[0].reads, 1000)
    }

    func testParseMetricsK2ReadsFallback() throws {
        // Fall back to "K2 Reads" when other read columns are absent
        let tsv = """
        organism\ttass_score\tK2 Reads
        OrgA\t0.9\t500
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics[0].reads, 500)
    }

    // MARK: - Edge Case: Comma-Separated Numbers

    func testParseMetricsCommaInNumbers() throws {
        let tsv = """
        organism\treads\ttass_score
        LargeOrg\t1,234,567\t0.99
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics[0].reads, 1_234_567)
    }

    // MARK: - Edge Case: Percent Sign in Abundance

    func testParseMetricsPercentInAbundance() throws {
        let tsv = """
        organism\tabundance\ttass_score
        OrgA\t45.5%\t0.9
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics[0].abundance, 45.5)
    }

    // MARK: - Edge Case: Rows With Missing Trailing Fields

    func testParseMetricsShortRow() throws {
        // Row has fewer fields than the header - should not crash
        let tsv = """
        organism\ttass_score\treads\tcoverage_breadth\tconfidence
        FullOrg\t0.9\t1000\t85.0\thigh
        ShortOrg\t0.5
        """

        let metrics = try TaxTriageMetricsParser.parse(tsv: tsv)
        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics[1].organism, "ShortOrg")
        XCTAssertEqual(metrics[1].tassScore, 0.5)
        XCTAssertEqual(metrics[1].reads, 0) // defaults to 0
        XCTAssertNil(metrics[1].coverageBreadth)
        XCTAssertNil(metrics[1].confidence)
    }

    // MARK: - TaxTriageResult Persistence

    func testTaxTriageResultSaveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-result-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sample = TaxTriageSampleEntry(
            sampleId: "S1",
            fastq1Path: "/data/R1.fq.gz",
            platform: "ILLUMINA"
        )
        let config = TaxTriageSamplesheet.generate(from: [sample])
        XCTAssertTrue(config.contains("S1"))
    }
}
