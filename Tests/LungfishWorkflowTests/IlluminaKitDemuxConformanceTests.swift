// IlluminaKitDemuxConformanceTests.swift - A built-in Illumina kit splits reads that carry the index in the read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The walk's file `demux-truseq.fastq` (Phase 3.0 lane DEMUX-ILLUMINA, re-walk finding S2) holds the 100 reads of
// Tests/Fixtures/sarscov2/test_1.fastq.gz then the 100 of test_2.fastq.gz. The first 80 are led by the TruSeq
// D701 index ATTACTCG, the next 80 by D702 TCCGGAGA, and the last 40 are bare, with quality I on each added base.
// Before the fix, a run with TruSeq Single Index Set A stopped in cutadapt with "Adapter sequence is empty".

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// A real-tool suite. Its name puts it in the conformance tier, and it skips when managed cutadapt or seqkit is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class IlluminaKitDemuxConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "illumina-kit-demux-conformance")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTools() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
    }

    private typealias Read = (name: String, sequence: String, quality: String)

    /// Writes the walk's input and returns the 200 fixture reads it was built from, without the added index.
    private func writeInput(to url: URL) throws -> [Read] {
        var reads: [Read] = []
        for fixture in ["test_1.fastq.gz", "test_2.fastq.gz"] {
            let lines = try ReadWriterFixtures.gunzip(ConformanceFixtures.sarscov2.appendingPathComponent(fixture))
                .split(separator: "\n").map(String.init)
            for index in stride(from: 0, to: lines.count, by: 4) {
                reads.append((String(lines[index].dropFirst()), lines[index + 1], lines[index + 3]))
            }
        }
        XCTAssertEqual(reads.count, 200)
        var text = ""
        for (index, read) in reads.enumerated() {
            let lead = index < 80 ? "ATTACTCG" : (index < 160 ? "TCCGGAGA" : "")
            text += "@\(read.name)\n\(lead)\(read.sequence)\n+\n\(String(repeating: "I", count: lead.count))\(read.quality)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return reads
    }

    func testTruSeqSingleIndexDemuxSplitsInlineIndexes() async throws {
        try await requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("demux-truseq.fastq")
        let reads = try writeInput(to: input)
        let output = project.appendingPathComponent("demux-out", isDirectory: true)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: input,
                barcodeKit: BarcodeKitRegistry.truseqSingleA,
                outputDirectory: output,
                barcodeLocation: .fivePrime,
                errorRate: 0.15,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        let counts = Dictionary(uniqueKeysWithValues: result.manifest.barcodes.map { ($0.barcodeID, $0.readCount) })
        XCTAssertEqual(counts["D701"], 80)
        XCTAssertEqual(counts["D702"], 80)
        XCTAssertEqual(
            counts.filter { $0.key != "D701" && $0.key != "D702" }.values.reduce(0, +), 0,
            "no read goes to another index"
        )
        XCTAssertEqual(result.manifest.unassigned.readCount, 40)

        let d701 = try XCTUnwrap(result.manifest.barcodes.first { $0.barcodeID == "D701" })
        let bundle = output.appendingPathComponent(d701.bundleRelativePath, isDirectory: true)
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        var first: FASTQRecord?
        for try await record in FASTQReader(validateSequence: false).records(from: payload) {
            first = record
            break
        }
        let firstRead = try XCTUnwrap(first)
        XCTAssertEqual(firstRead.sequence.count, ("ATTACTCG" + reads[0].sequence).count - 8, "trim takes the 8-base index")
        XCTAssertEqual(firstRead.sequence, reads[0].sequence)
    }
}
