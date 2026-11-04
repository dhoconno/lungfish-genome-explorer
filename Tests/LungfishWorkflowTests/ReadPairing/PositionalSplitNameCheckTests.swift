// PositionalSplitNameCheckTests.swift - A split by position stops at the first two records that are not mates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Row READ-LAYOUT-PARTIAL-SCAN (BIO ruling, item 9). The split checked only for an odd total, so an even total of
/// mixed reads wrote false pairs with no warning. The name check is the second guard behind the whole-file scan.
final class PositionalSplitNameCheckTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "positional-split-names")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func split(_ input: URL) throws -> FASTQPairInterleaver.Counts {
        let r1 = root.appendingPathComponent("\(UUID().uuidString)_R1.fastq")
        let r2 = root.appendingPathComponent("\(UUID().uuidString)_R2.fastq")
        FileManager.default.createFile(atPath: r1.path, contents: nil)
        FileManager.default.createFile(atPath: r2.path, contents: nil)
        let handle1 = try FileHandle(forWritingTo: r1)
        let handle2 = try FileHandle(forWritingTo: r2)
        defer {
            try? handle1.close()
            try? handle2.close()
        }
        return try FASTQPairInterleaver.deinterleave(interleaved: input, r1: handle1, r2: handle2)
    }

    /// Even and odd totals both stop at the first false pair, the pair after the 60,000 true ones.
    func testDeinterleaveThrowsMateNameMismatchOnFalsePair() throws {
        for merged in [20_000, 20_001] {
            let input = root.appendingPathComponent("mixed-\(merged).fastq")
            try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(merged)], to: input)
            XCTAssertThrowsError(try split(input), "\(merged) merged reads") { error in
                guard case FASTQPairInterleaver.InterleaveError.mateNameMismatch(
                    let recordNumber, _, let r1Name, _, let r2Name
                ) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(recordNumber, 60_001)
                XCTAssertEqual(r1Name, "m0")
                XCTAssertEqual(r2Name, "m1")
                let words = error.localizedDescription
                XCTAssertTrue(words.contains("m0") && words.contains("m1"), words)
                XCTAssertFalse(words.contains("two files"), "one file was split: \(words)")
            }
        }
    }

    /// The control. Each naming LGE reads as mates still splits, record for record.
    func testTrueStrictFilesStillSplitAsPairs() throws {
        let namings: [(name: String, headers: [String])] = [
            ("suffixes", ["a/1", "a/2", "b/1", "b/2"]),
            ("casava", ["a 1:N:0:AC", "a 2:N:0:AC", "b 1:N:0:AC", "b 2:N:0:AC"]),
            ("identical", ["a", "a", "b", "b"]),
        ]
        for naming in namings {
            let input = root.appendingPathComponent("\(naming.name).fastq")
            try naming.headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
                .write(to: input, atomically: true, encoding: .utf8)
            let counts = try split(input)
            XCTAssertEqual(counts.r1Records, 2, naming.name)
            XCTAssertEqual(counts.r2Records, 2, naming.name)
        }
    }

    /// The split Kraken 2 and TaxTriage share leaves no half behind when it stops.
    func testTheSharedSplitRemovesItsHalvesOnAFalsePair() async throws {
        let input = root.appendingPathComponent("mixed.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(100), .singles(20)], to: input)
        let directory = root.appendingPathComponent("halves", isDirectory: true)
        do {
            _ = try await ClassificationPipeline.splitInterleavedInput(input, into: directory)
            XCTFail("the split must stop at the first false pair")
        } catch {
            guard case FASTQPairInterleaver.InterleaveError.mateNameMismatch = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
