// FastqErrorCorrectReadOrderTests.swift - Error correction keeps every read in input order, so mates stay side by side
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Final review A, N7. `fastq error-correct` runs tadpole on every record on
// its own and drops none, but tadpole wrote its chunks of reads as its
// threads finished them. On a file that mixes pairs with single reads, a
// pair that straddled two chunks lost its adjacency: 41 of 8,535 pairs of
// the HG002 chrM fixture, with a single read after every seventh pair. A
// later tool that pairs by name then reads both mates as orphans. tadpole
// now runs `ordered=t`, which writes the same records in input order.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishTestSupport
@testable import LungfishWorkflow

final class FastqErrorCorrectReadOrderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "error-correct-read-order")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testErrorCorrectionWritesEveryReadInInputOrder() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.tadpole) else {
            try ToolAvailability.skipOrFail("managed tadpole is not installed")
        }
        let fixtures = CLITestBinaryResolver.repositoryRoot(containing: #filePath)
            .appendingPathComponent("docs/user-manual/fixtures/human-mito", isDirectory: true)
        let r1 = try Self.records(ofGzip: fixtures.appendingPathComponent("HG002.chrM_R1.fastq.gz"))
        let r2 = try Self.records(ofGzip: fixtures.appendingPathComponent("HG002.chrM_R2.fastq.gz"))
        XCTAssertEqual(r1.count, r2.count)
        XCTAssertGreaterThan(r1.count, 5_000, "the fixture spans many of tadpole's chunks")

        // Every seventh fragment keeps only its first mate, renamed as a
        // single read, so single reads sit between pairs all through the file.
        var records: [[Substring]] = []
        for (index, (mate1, mate2)) in zip(r1, r2).enumerated() {
            if index % 7 == 3 {
                records.append([Substring("@single_\(index)")] + mate1.dropFirst())
            } else {
                records += [mate1, mate2]
            }
        }
        let input = root.appendingPathComponent("mixed.fastq")
        try records.map { $0.joined(separator: "\n") + "\n" }.joined().write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("corrected.fastq")

        try await FastqErrorCorrectSubcommand.parse([input.path, "-o", output.path]).run()

        let names = try ReadSetFixtures.readNames(in: output)
        XCTAssertEqual(names.count, records.count, "no read is dropped")
        XCTAssertEqual(names, try ReadSetFixtures.readNames(in: input), "every read is written in input order")
    }

    /// The four-line records of a gzip-compressed FASTQ file.
    private static func records(ofGzip url: URL) throws -> [[Substring]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, url.lastPathComponent)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count - 3, by: 4).map { Array(lines[$0..<$0 + 4]) }
    }
}
