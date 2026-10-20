// NaoMgsSamplePartitionerStreamPinTests.swift - Pins of the NAO-MGS partitioner's line stream, from before Phase 2.13 lane 13.07
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// About 9 MB of NAO-MGS rows over three samples, which is more than two of the partitioner's 4 MiB chunks, with a
/// last row that has no newline, and the file each sample must receive.
enum NaoMgsPartitionPinFixture {
    static let rows = 110_000
    static let header = "sample\tseq_id\tvalue"

    static func tsv() -> (data: Data, expected: [String: Data]) {
        let samples = ["alpha", "beta", "gamma"]
        let value = String(repeating: "ACGTTGCA", count: 8)
        var text = header + "\n"
        var perSample = Dictionary(uniqueKeysWithValues: samples.map { ($0, header + "\n") })
        for index in 0..<rows {
            let sample = samples[index % samples.count]
            let row = "\(sample)\tid-\(index)\t\(value)"
            text += index == rows - 1 ? row : row + "\n"
            perSample[sample, default: ""] += row + "\n"
        }
        return (Data(text.utf8), perSample.mapValues { Data($0.utf8) })
    }

    static func assertPartition(
        _ result: NaoMgsPartitionResult,
        expected: [String: Data],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(result.totalRows, rows, file: file, line: line)
        XCTAssertEqual(Set(result.sampleFiles.keys), Set(expected.keys), file: file, line: line)
        for (sample, url) in result.sampleFiles {
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(
                GzipPin.sha256Hex(bytes), GzipPin.sha256Hex(expected[sample] ?? Data()),
                "the file of \(sample)", file: file, line: line
            )
        }
    }
}

/// The plain-input half, which needs no tool.
final class NaoMgsSamplePartitionerStreamPinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "naomgs-stream-pins")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    func testPlainInputHandsEveryRowToItsSampleByteForByte() throws {
        let (data, expected) = NaoMgsPartitionPinFixture.tsv()
        XCTAssertGreaterThan(data.count, 2 * 4_194_304)
        let input = scratch.appendingPathComponent("reads.tsv")
        try data.write(to: input)
        let result = try NaoMgsSamplePartitioner.partition(
            inputURLs: [input], outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
        )
        try NaoMgsPartitionPinFixture.assertPartition(result, expected: expected)
    }
}

/// The gzip-input half, which runs the managed pigz and so never runs in the unit tier. Run it with
/// `LUNGFISH_REQUIRE_TOOLS=1` where the managed pigz is installed, and it skips where it is not.
final class NaoMgsSamplePartitionerPigzConformanceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "naomgs-pigz-pins")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    private func requirePigz() throws {
        guard NaoMgsSamplePartitioner.managedDecompressorURL() != nil else {
            try ToolAvailability.skipOrFail("managed pigz is not installed")
        }
    }

    func testGzipInputHandsEveryRowToItsSampleByteForByte() throws {
        try requirePigz()
        let (data, expected) = NaoMgsPartitionPinFixture.tsv()
        let input = scratch.appendingPathComponent("reads.tsv.gz")
        try GzipPin.gzip(["-n", "-c"], stdin: data).write(to: input)
        let result = try NaoMgsSamplePartitioner.partition(
            inputURLs: [input], outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
        )
        try NaoMgsPartitionPinFixture.assertPartition(result, expected: expected)
    }

    func testCorruptGzipInputNamesTheFileAndTheExitStatus() throws {
        try requirePigz()
        let bad = scratch.appendingPathComponent("bad.tsv.gz")
        try Data(String(repeating: "this is not gzip data\n", count: 20).utf8).write(to: bad)
        XCTAssertThrowsError(
            try NaoMgsSamplePartitioner.partition(
                inputURLs: [bad], outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription, "Failed to decompress NAO-MGS gzip input bad.tsv.gz (exit 1)"
            )
        }
    }
}
