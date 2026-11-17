// FASTQSampleSheetSingleEndTests.swift - The sheet entry point that takes an empty r2 cell (CHTC-QUANT-SINGLE-END milestone 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `samplePairsAllowingSingleEnd` is the one entry point of `rnaseq quant --write-plan --staged-reads`. The readers that
// `import fastq`, `rnaseq solo-plan` and the app call keep refusing an empty r2 cell, in the words they always had.

import XCTest
@testable import LungfishWorkflow

final class FASTQSampleSheetSingleEndTests: XCTestCase {
    let sheet = URL(fileURLWithPath: "/data/sheets/samples.csv")

    func pairs(_ csv: String) throws -> [SamplePair] {
        try FASTQSampleSheet.samplePairsAllowingSingleEnd(csv: csv, sourceURL: sheet)
    }

    /// An empty r2 cell is one sample with one read file and no mate, a row with an r2 keeps its pair, and the model and kit
    /// columns come through as metadata for both.
    func testAnEmptyR2CellIsOneReadFileAndTheOtherRowsKeepTheirPairs() throws {
        let csv = "sample,r1,r2,model,kit\nS1,/reads/S1.fastq.gz,,Illumina NovaSeq 6000,\nS2,S2_1.fastq.gz,S2_2.fastq.gz,NovaSeq,\"a, b\"\n"
        let made = try pairs(csv)
        XCTAssertEqual(made.map(\.sampleName), ["S1", "S2"])
        XCTAssertEqual(made[0].r1.path, "/reads/S1.fastq.gz")
        XCTAssertNil(made[0].r2)
        XCTAssertEqual(made[0].inputFiles.map(\.path), ["/reads/S1.fastq.gz"])
        XCTAssertEqual(made[0].metadata, ["model": "Illumina NovaSeq 6000"])
        XCTAssertEqual(made[1].r1.path, "/data/sheets/S2_1.fastq.gz", "a relative path is read from the sheet's folder")
        XCTAssertEqual(made[1].r2?.path, "/data/sheets/S2_2.fastq.gz")
        XCTAssertEqual(made[1].metadata, ["model": "NovaSeq", "kit": "a, b"])
        XCTAssertEqual(made.map(\.sampleSheetURL), [sheet, sheet])
    }

    /// On a sheet with no empty r2 cell the new entry point and `parse(...).samplePairs()` give the same pairs, field for
    /// field, so the two readers cannot drift apart, and `parse` still refuses an empty r2 cell as it always has.
    func testASheetWithNoEmptyR2ReadsAsParseDoesAndParseStillRefusesAnEmptyR2() throws {
        let csv = "Sample, R1 ,r2,note\n\"S,1\",~/a.fastq,b.fastq,x\nS2,c.fastq,\"d.fastq\",\n"
        let parsed = try FASTQSampleSheet.parse(csv: csv, sourceURL: sheet).samplePairs()
        let made = try pairs(csv)
        XCTAssertEqual(made.count, parsed.count)
        for (one, other) in zip(made, parsed) {
            XCTAssertEqual(one.sampleName, other.sampleName)
            XCTAssertEqual(one.r1, other.r1)
            XCTAssertEqual(one.r2, other.r2)
            XCTAssertNotNil(one.r2)
            XCTAssertEqual(one.unpaired, other.unpaired)
            XCTAssertEqual(one.relativePath, other.relativePath)
            XCTAssertEqual(one.metadata, other.metadata)
            XCTAssertEqual(one.sampleSheetURL, other.sampleSheetURL)
        }
        let single = "sample,r1,r2\nS1,a.fastq,\n"
        XCTAssertThrowsError(try FASTQSampleSheet.parse(csv: single, sourceURL: sheet)) {
            XCTAssertEqual($0 as? FASTQSampleSheetError, .emptyValue(column: "r2", line: 2))
            XCTAssertEqual($0.localizedDescription, "Sample sheet line 2 has an empty r2 value.")
        }
        XCTAssertEqual(try pairs(single).map(\.sampleName), ["S1"])
    }

    /// The r2 column stays required, the sample and r1 cells stay non-empty, and a sheet with no row is empty.
    func testTheR2ColumnStaysRequiredAndTheSampleAndR1CellsStayNonEmpty() {
        let cases: [(String, FASTQSampleSheetError)] = [
            ("sample,r1\nS1,a.fastq\n", .missingRequiredColumns),
            ("sample,r1,r2\nS1,a.fastq,b.fastq\n,c.fastq,\n", .emptyValue(column: "sample", line: 3)),
            ("sample,r1,r2\nS1,,\n", .emptyValue(column: "r1", line: 2)),
            ("sample,r1,r2\n", .emptyFile),
            ("", .emptyFile),
        ]
        for (csv, expected) in cases {
            XCTAssertThrowsError(try pairs(csv), csv) { XCTAssertEqual($0 as? FASTQSampleSheetError, expected, csv) }
        }
    }
}
