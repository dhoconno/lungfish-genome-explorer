// LoosePairShortMateTests+Formats.swift - Loose pairs that are not FASTQ or FASTA by name are refused, and FASTA pairs
// are counted, on the Kraken2, EsViritu and TaxTriage routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// BIO ruling BIO-ROUTES-2, binding items 3, 4 and 7. The loose-pair check skipped a pair it could not name as FASTQ, so a
/// `.fastq.bz2` or extension-less pair, and a FASTA pair, reached kraken2, EsViritu or TaxTriage unchecked. A pair
/// outside any bundle that is not FASTQ or FASTA by name is now refused with the format words, and a FASTA pair, plain
/// or gzip, is counted and its names compared.
extension LoosePairShortMateTests {

    static let bz2Words = "Paired reads must be FASTQ or FASTA files ending .fastq, .fq, .fasta or .fa, plain or .gz. S_R1.fastq.bz2 is not. Nothing ran. Decompress or rename it, or run each file as single reads."
    static let extensionlessWords = "Paired reads must be FASTQ or FASTA files ending .fastq, .fq, .fasta or .fa, plain or .gz. S_R2 is not. Nothing ran. Decompress or rename it, or run each file as single reads."

    /// TaxTriage took a `.bz2` pair unchecked and now gives the format words. EsViritu and Kraken2 refuse such a file
    /// earlier with their own words, at the base and after the fix, as map and assemble do.
    func testABz2PairIsRefusedByEveryLoosePairedRoute() async throws {
        let r1 = try writeMates("S_R1.fastq.bz2", mate: 1, count: 200)
        let r2 = try writeMates("S_R2.fastq.bz2", mate: 2, count: 120)
        try await assertFormatRefusals(r1: r1, r2: r2, formatWords: Self.bz2Words, unreadable: r1)
    }

    func testAnR2WithNoExtensionIsRefusedByEveryLoosePairedRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 200)
        let r2 = try writeMates("S_R2", mate: 2, count: 200)
        try await assertFormatRefusals(r1: r1, r2: r2, formatWords: Self.extensionlessWords, unreadable: r2)
    }

    /// One comparison of every route's words and exit code (FIX-ROUTES-SWIFT SF2's table form).
    func assertFormatRefusals(r1: URL, r2: URL, formatWords: String, unreadable: URL) async throws {
        var observed: [String] = []
        var expected: [String] = []
        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            observed.append("\(route.rawValue) | \(refusal.words ?? "nil") | \(refusal.exitCode.map(String.init) ?? "nil")")
            switch route {
            case .taxTriageInput2, .taxTriageSamplesheet:
                expected.append("\(route.rawValue) | \(formatWords) | 3")
            case .esVirituPaired, .esVirituBatch:
                expected.append("\(route.rawValue) | Sequence input does not contain a readable FASTQ or FASTA payload: \(unreadable.path) | 3")
            case .kraken2Paired, .kraken2Batch:
                expected.append("\(route.rawValue) | Could not detect format for file: \(unreadable.path) | 3")
            }
        }
        XCTAssertEqual(observed, expected)
    }

    /// Item 3 at the shared check: a gzip FASTA R2 cut to 120 records, a plain FASTA R2 out of step, and an equal gzip
    /// pair, which passes.
    func testTheCheckCountsAndNamesAPlainOrGzipFASTAPair() async throws {
        let r1 = try writeFASTARecords("S_R1.fa", names: (1...200).map { "frag\($0)/1" })
        let cutPlain = try writeFASTARecords("cut-R2.fa", names: (1...120).map { "frag\($0)/2" })
        let cutR2 = loose.appendingPathComponent("S_R2.fa.gz")
        try await SystemToolProbe.gzip(cutPlain, to: cutR2)
        XCTAssertEqual(
            try LooseMatePairCheck.refusal(r1: r1, r2: cutR2),
            "Paired FASTA mates do not match. S_R1.fa has 200 reads, but S_R2.fa.gz has 120. Nothing ran. Check that both files are complete or run each as single reads.")

        var names = (1...200).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        let shuffled = try writeFASTARecords("S_R2.fa", names: names)
        XCTAssertEqual(
            try LooseMatePairCheck.refusal(r1: r1, r2: shuffled),
            "Paired FASTA mates are out of step at read 2. S_R1.fa has 'frag2/1', but S_R2.fa has 'frag3/2'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads.")

        let equalPlain = try writeFASTARecords("equal-R2.fa", names: (1...200).map { "frag\($0)/2" })
        let equalR2 = root.appendingPathComponent("equal").appendingPathComponent("S_R2.fa.gz")
        try FileManager.default.createDirectory(at: equalR2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await SystemToolProbe.gzip(equalPlain, to: equalR2)
        XCTAssertEqual(try LooseMatePairCheck.refusal(r1: r1, r2: equalR2), nil)
    }

    /// Writes one two-line record for each name to `name` in the loose folder.
    func writeFASTARecords(_ name: String, names: [String]) throws -> URL {
        let url = loose.appendingPathComponent(name)
        try Data(names.map { ">\($0)\nACGTACGTAC\nGTACGTACGT\n" }.joined().utf8).write(to: url)
        return url
    }
}
