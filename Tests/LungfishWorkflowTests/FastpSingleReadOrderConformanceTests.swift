// FastpSingleReadOrderConformanceTests.swift - A single-read trim gives the same reads in any read order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-PROBES-E (S1). fastp guesses a single-end adapter from the reads it sees first, so two orders of the same
// reads gave two adapters and two results, and staging the reads in a seeded order only fixed which guess was made.
// The fixture is 16,000 reads of SRR14639650 (Tests/Fixtures/fastp-single-read-order/README.md). The stand-in cases are
// in FastpStagedReadOrderTests.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FastpSingleReadOrderConformanceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let folder = try TestTempDirectory.make(prefix: "fastp-single-read-order")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        root = folder
    }

    private func records(_ url: URL) throws -> [String] {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var lines: [String] = []
        while let line = try reader.nextLine() {
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return stride(from: 0, to: lines.count, by: 4).map { lines[$0..<$0 + 4].joined(separator: "\n") }
    }

    private func trim(_ reads: [String], tag: String) async throws -> [String] {
        let input = root.appendingPathComponent("in-\(tag).fastq")
        try (reads.joined(separator: "\n") + "\n").write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out-\(tag).fastq")
        _ = try await FastpPairedRunner.run(
            inputURL: input, outputPath: output.path, plan: .singleEnd,
            options: FastpTrimOptions.options(for: .adapter(sequence: nil, sequenceR2: nil, adapterFastaPath: nil), threads: 1),
            detectPairedAdapters: true, failureLabel: "fastp adapter trim", stepNamePrefix: "lungfish fastq adapter-trim"
        )
        return try records(output)
    }

    func testSingleReadTrimGivesTheSameReadsInEitherOrder() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.fastp) else {
            try ToolAvailability.skipOrFail("fastp is not available in this test environment")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fastp-single-read-order/SRR14639650-16000.fastq.gz")
        let reads = try records(fixture)
        XCTAssertEqual(reads.count, 16_000)

        let fileOrder = try await trim(reads, tag: "file").sorted()
        let reversed = try await trim(reads.reversed(), tag: "reversed").sorted()

        func bases(_ trimmed: [String]) -> Int {
            trimmed.reduce(0) { $0 + $1.split(separator: "\n")[1].count }
        }
        XCTAssertEqual(fileOrder.count, 15_941, "reads out, from fastp run directly with the named adapters")
        XCTAssertEqual(bases(fileOrder), 1_360_663, "bases out, from fastp run directly with the named adapters")
        XCTAssertEqual(reversed.count, fileOrder.count, "the same reads come out in either order")
        XCTAssertEqual(bases(reversed), bases(fileOrder), "the same bases come out in either order")
        XCTAssertTrue(reversed == fileOrder, "the trimmed reads are the same, byte for byte, in either order")
    }
}
