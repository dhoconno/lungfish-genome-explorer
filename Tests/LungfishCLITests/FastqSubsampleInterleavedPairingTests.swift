// FastqSubsampleInterleavedPairingTests.swift - SCI-16: pair-aware subsampling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish fastq subsample` is the CLI command the FASTQ Operations dialog
// invokes for "Subsample by Proportion"/"Subsample by Count". Paired imports
// are stored on disk as a single interleaved FASTQ (mates on adjacent
// records). `seqkit sample`/`sample2` samples records independently, which
// can orphan a mate. This test proves that an interleaved input keeps mates
// together after subsampling (SCI-16).

import Foundation
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqSubsampleInterleavedPairingTests: XCTestCase {
    func testSubsampleByProportionKeepsMatesTogetherOnInterleavedInput() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.reformat) else {
            throw XCTSkip("bbtools reformat.sh is not available in this test environment")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-subsample-interleaved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("interleaved.fastq")
        try writeInterleavedFixture(pairCount: 200, to: inputURL)

        let outputURL = root.appendingPathComponent("subsampled.fastq")
        let command = try FastqSubsampleSubcommand.parse([
            inputURL.path,
            "--proportion", "0.5",
            "--seed", "42",
            "-o", outputURL.path,
        ])
        try await command.run()

        let records = try await readAllRecords(at: outputURL)
        XCTAssertGreaterThan(records.count, 0, "Subsampling must not produce an empty file")
        XCTAssertEqual(records.count % 2, 0, "An interleaved output must keep an even number of records (whole pairs only)")

        var index = 0
        while index < records.count {
            let mate1 = records[index]
            let mate2 = records[index + 1]
            let key1 = IlluminaAmpliconPairMerger.fragmentKey(identifier: mate1.identifier, description: mate1.description)
            let key2 = IlluminaAmpliconPairMerger.fragmentKey(identifier: mate2.identifier, description: mate2.description)
            XCTAssertEqual(
                key1, key2,
                "Record \(index)/\(index + 1) must be mates of the same fragment, found '\(mate1.identifier)' next to '\(mate2.identifier)'"
            )
            let mate1Number = IlluminaAmpliconPairMerger.mateNumber(identifier: mate1.identifier, description: mate1.description)
            let mate2Number = IlluminaAmpliconPairMerger.mateNumber(identifier: mate2.identifier, description: mate2.description)
            XCTAssertEqual(mate1Number, 1)
            XCTAssertEqual(mate2Number, 2)
            index += 2
        }
    }

    func testSubsampleByCountKeepsMatesTogetherOnInterleavedInput() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.reformat) else {
            throw XCTSkip("bbtools reformat.sh is not available in this test environment")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-subsample-interleaved-count-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("interleaved.fastq")
        try writeInterleavedFixture(pairCount: 200, to: inputURL)

        let outputURL = root.appendingPathComponent("subsampled.fastq")
        let command = try FastqSubsampleSubcommand.parse([
            inputURL.path,
            "--count", "50",
            "--seed", "7",
            "-o", outputURL.path,
        ])
        try await command.run()

        let records = try await readAllRecords(at: outputURL)
        // --count is a read count (the dialog says "Keep a fixed number of
        // reads"), so 50 reads means 25 whole pairs, never 50 pairs.
        XCTAssertEqual(records.count, 50, "Requesting 50 reads must yield exactly 50 records (25 whole pairs)")

        var index = 0
        while index < records.count {
            let mate1 = records[index]
            let mate2 = records[index + 1]
            let key1 = IlluminaAmpliconPairMerger.fragmentKey(identifier: mate1.identifier, description: mate1.description)
            let key2 = IlluminaAmpliconPairMerger.fragmentKey(identifier: mate2.identifier, description: mate2.description)
            XCTAssertEqual(key1, key2, "Record \(index)/\(index + 1) must be mates of the same fragment")
            index += 2
        }
    }

    // MARK: - Fixture helpers

    private func writeInterleavedFixture(pairCount: Int, to url: URL) throws {
        var lines: [String] = []
        for i in 0..<pairCount {
            lines.append("@frag\(i)/1")
            lines.append("ACGTACGTAC")
            lines.append("+")
            lines.append("IIIIIIIIII")
            lines.append("@frag\(i)/2")
            lines.append("TGCATGCATG")
            lines.append("+")
            lines.append("IIIIIIIIII")
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func readAllRecords(at url: URL) async throws -> [FASTQRecord] {
        var records: [FASTQRecord] = []
        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }
}
