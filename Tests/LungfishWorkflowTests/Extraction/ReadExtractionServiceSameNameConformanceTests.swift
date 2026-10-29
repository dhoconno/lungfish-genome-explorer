// ReadExtractionServiceSameNameConformanceTests.swift - By-ID extraction keeps both mates of an SRA-named read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane FASTQ-SAME-NAME, finding F1 of its first report (S1, narrow). `extractByReadIDsFromBAM` collates the
// records it selected by name and runs `samtools fastq` (or `fasta`) over them. Collating puts both records of one name
// side by side, and `samtools fastq` writes one record for two side-by-side records of one name when neither carries
// READ1 or READ2, so an SRA-named read whose two mates were mapped as single reads lost a mate while the count the
// extraction reports (the records it selected) still held it.
//
// Tiny BAMs are built from SAM text with the managed samtools. The reads here are: `r1`, two records (flags 0 and 16, the
// second the reverse strand), and `r2`, one record. Each record carries its own sequence and qualities, so a dropped or
// mixed-up record shows in the text. The reverse record is written as the read, reverse-complemented with reversed
// qualities. The record order of the unflagged reads is the collate order, so the tests compare sorted records.
//
// It runs the managed samtools, so its name holds Conformance and it skips without it unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ReadExtractionServiceSameNameConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-extraction-same-name")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    // MARK: - Cases

    /// Both mates of `r1` and the read `r2`, as FASTQ. The base wrote `r1` once, two records for the three selected.
    func testByIDExtractionKeepsBothMatesOfAnSraNameMappedAsSingleReads() async throws {
        try await ClassifierReadIDListSupport.requireTool(.samtools)
        let bam = try await makeBAM("sra-names", records: singleReadRecords)
        let result = try await extract(bam, ids: ["r1", "r2"], format: .fastq)
        XCTAssertEqual(result.readCount, 3, "the count the extraction reports is the records it selected")
        let output = try XCTUnwrap(result.outputURLs.first)
        XCTAssertEqual(
            try records(in: output, linesPerRecord: 4),
            [
                "@r1\nAAAACCCCGG\n+\nABCDEFGHIJ\n",
                "@r1\nTTTTGGGGAA\n+\n0123456789\n",
                "@r2\nCCCCGGGGTT\n+\n0000011111\n",
            ],
            "both mates of r1 are written, the reverse one restored, and r2"
        )
    }

    /// The same reads as FASTA, which `samtools fasta` collapsed in the same way.
    func testByIDExtractionAsFASTAKeepsBothMatesOfAnSraNameMappedAsSingleReads() async throws {
        try await ClassifierReadIDListSupport.requireTool(.samtools)
        let bam = try await makeBAM("sra-names-fasta", records: singleReadRecords)
        let result = try await extract(bam, ids: ["r1", "r2"], format: .fasta)
        XCTAssertEqual(result.readCount, 3, "the count the extraction reports is the records it selected")
        let output = try XCTUnwrap(result.outputURLs.first)
        XCTAssertEqual(
            try records(in: output, linesPerRecord: 2),
            [">r1\nAAAACCCCGG\n", ">r1\nTTTTGGGGAA\n", ">r2\nCCCCGGGGTT\n"],
            "both mates of r1 are written, the reverse one restored, and r2"
        )
    }

    // MARK: - Helpers

    private var singleReadRecords: [String] {
        [
            Self.record("r1", 0, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
            Self.record("r1", 16, pos: 300, seq: "TTCCCCAAAA", qual: "9876543210"),
            Self.record("r2", 0, pos: 400, seq: "CCCCGGGGTT", qual: "0000011111"),
            Self.record("other", 0, pos: 500, seq: "ACGTACGTAC", qual: "IIIIIIIIII"),
        ]
    }

    private static let samHeader = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:ref\tLN:1000\n"

    /// One SAM line. `seq` and `qual` are as the file holds them, so a reverse-strand record carries its bases as they
    /// were aligned.
    private static func record(
        _ name: String, _ flag: Int, pos: Int, seq: String, qual: String, mate: (ref: String, pos: Int) = ("*", 0)
    ) -> String {
        [name, String(flag), "ref", String(pos), "60", "\(seq.count)M", mate.ref, String(mate.pos), "0", seq, qual]
            .joined(separator: "\t")
    }

    private func makeBAM(_ name: String, records: [String]) async throws -> URL {
        let sam = root.appendingPathComponent("\(name).sam")
        try (Self.samHeader + records.joined(separator: "\n") + "\n").write(to: sam, atomically: true, encoding: .utf8)
        let bam = root.appendingPathComponent("\(name).bam")
        let result = try await NativeToolRunner.shared.run(
            .samtools, arguments: ["view", "-b", "-o", bam.path, sam.path], timeout: 60
        )
        XCTAssertTrue(result.isSuccess, "samtools view -b failed: \(result.stderr)")
        return bam
    }

    /// A by-ID extraction of `ids` from `bam` into a folder of its own.
    private func extract(_ bam: URL, ids: Set<String>, format: ReadIDBAMExtractionFormat) async throws -> ReadIDBAMExtractionResult {
        let folder = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        let config = ReadIDBAMExtractionConfig(
            bamURL: bam, readIDs: ids, format: format, outputDirectory: folder, outputBaseName: "by-id"
        )
        return try await ReadExtractionService().extractByReadIDsFromBAM(config: config)
    }

    /// The records of a FASTQ or FASTA file, each as its lines with a final newline, sorted.
    private func records(in url: URL, linesPerRecord: Int) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        return stride(from: 0, to: lines.count, by: linesPerRecord).map { start in
            lines[start..<min(start + linesPerRecord, lines.count)].joined(separator: "\n") + "\n"
        }.sorted()
    }
}
