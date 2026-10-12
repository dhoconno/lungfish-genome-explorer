// NextflowSamplesheetBuilderTests.swift - TaxTriage's samplesheet builder against the sheet the pipeline writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (panel N1). The builder writes the sheet a TaxTriage run reads as `--input`. The tests
// write the same samples twice, once through the builder and once as `TaxTriagePipeline.swift:340-349` writes
// them, and compare the bytes. Pure apart from a scratch folder in the system temporary folder, which the
// teardown removes, so it runs in the unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class NextflowSamplesheetBuilderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextflow-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
    }

    /// One sample of each shape the sheet holds. Paired Illumina reads, single Nanopore reads under a path with a
    /// space, PacBio reads under a name with a comma, and reads under a path with quotes.
    private let samples = [
        TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"),
            fastq2: URL(fileURLWithPath: "/data/S1_R2.fastq.gz"),
            platform: .illumina),
        TaxTriageSample(
            sampleId: "ONT_run1",
            fastq1: URL(fileURLWithPath: "/data/ont run/reads.fastq.gz"),
            platform: .oxford),
        TaxTriageSample(
            sampleId: "Pac,Bio",
            fastq1: URL(fileURLWithPath: "/data/hifi.fq"),
            platform: .pacbio),
        TaxTriageSample(
            sampleId: "Q1",
            fastq1: URL(fileURLWithPath: "/data/\"quoted\".fq.gz"),
            platform: .illumina),
    ]

    /// The sheet today's pipeline writes for `samples` into the output folder `name`, through the entries and the
    /// writer `TaxTriagePipeline.swift:340-349` uses.
    private func pipelineSheet(_ samples: [TaxTriageSample], name: String) throws -> Data {
        let config = TaxTriageConfig(
            samples: samples, outputDirectory: scratch.appendingPathComponent(name, isDirectory: true))
        try TaxTriageSamplesheet.write(
            samples: TaxTriagePipeline.samplesheetEntries(for: config), to: config.samplesheetURL)
        return try Data(contentsOf: config.samplesheetURL)
    }

    /// The rows any builder gives, read through the protocol as the engine's callers read them.
    private func protocolRows<Builder: NextflowSamplesheetBuilding>(
        _ builder: Builder, _ samples: [Builder.Sample]
    ) throws -> [[String]] {
        try builder.rows(for: samples)
    }

    func testTheSheetIsByteEqualToTheSheetThePipelineWrites() throws {
        let url = scratch.appendingPathComponent("builder/not-yet/samplesheet.csv")
        try TaxTriageSamplesheetBuilder().write(samples, to: url)

        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, try pipelineSheet(samples, name: "pipeline"))
        XCTAssertEqual(
            String(decoding: written, as: UTF8.self),
            """
            sample,fastq_1,fastq_2,platform
            S1,/data/S1_R1.fastq.gz,/data/S1_R2.fastq.gz,ILLUMINA
            ONT_run1,/data/ont run/reads.fastq.gz,,OXFORD
            "Pac,Bio",/data/hifi.fq,,PACBIO
            Q1,"/data/""quoted"".fq.gz",,ILLUMINA

            """)
    }

    func testEachSampleGivesOneRowKeyedByItsName() throws {
        let rows = try protocolRows(TaxTriageSamplesheetBuilder(), samples)
        XCTAssertEqual(rows, [
            ["S1", "/data/S1_R1.fastq.gz", "/data/S1_R2.fastq.gz", "ILLUMINA"],
            ["ONT_run1", "/data/ont run/reads.fastq.gz", "", "OXFORD"],
            ["Pac,Bio", "/data/hifi.fq", "", "PACBIO"],
            ["Q1", "/data/\"quoted\".fq.gz", "", "ILLUMINA"],
        ])
        XCTAssertEqual(rows.map(\.first), samples.map(\.sampleId))

        // The rows are the entries today's pipeline writes, field by field.
        let config = TaxTriageConfig(samples: samples, outputDirectory: scratch)
        let entries = TaxTriagePipeline.samplesheetEntries(for: config)
        XCTAssertEqual(rows, entries.map { [$0.sampleId, $0.fastq1Path, $0.fastq2Path ?? "", $0.platform] })
    }

    func testTwoSamplesWithOneNameAreRefusedAsTheConfigRefusesThemAndNothingIsWritten() throws {
        let reads = try ["a.fq", "b.fq", "c.fq"].map { name -> URL in
            let url = scratch.appendingPathComponent(name)
            try Data("@r\nA\n+\nI\n".utf8).write(to: url)
            return url
        }
        let shared = [
            TaxTriageSample(sampleId: "S2", fastq1: reads[0]),
            TaxTriageSample(sampleId: "S1", fastq1: reads[1]),
            TaxTriageSample(sampleId: "S2", fastq1: reads[2]),
            TaxTriageSample(sampleId: "S1", fastq1: reads[0]),
        ]

        let builder = TaxTriageSamplesheetBuilder()
        XCTAssertThrowsError(try builder.rows(for: shared)) { error in
            guard case TaxTriageConfigError.duplicateSampleIds(let names) = error else {
                return XCTFail("Threw \(error) instead of duplicateSampleIds")
            }
            XCTAssertEqual(names, ["S1", "S2"])
            XCTAssertEqual(error.localizedDescription, "Duplicate sample IDs: S1, S2")
        }

        // The configuration the pipeline validates before it writes the sheet refuses the same samples alike.
        let config = TaxTriageConfig(samples: shared, outputDirectory: scratch.appendingPathComponent("out"))
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error.localizedDescription, "Duplicate sample IDs: S1, S2")
        }

        let url = scratch.appendingPathComponent("refused/samplesheet.csv")
        XCTAssertThrowsError(try builder.write(shared, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testNoSamplesGiveNoRowsAndTheHeaderAloneAsThePipelineWritesIt() throws {
        let builder = TaxTriageSamplesheetBuilder()
        XCTAssertEqual(try builder.rows(for: []), [])

        let url = scratch.appendingPathComponent("empty/samplesheet.csv")
        try builder.write([], to: url)
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, try pipelineSheet([], name: "pipeline-empty"))
        XCTAssertEqual(String(decoding: written, as: UTF8.self), "sample,fastq_1,fastq_2,platform\n")
    }
}
