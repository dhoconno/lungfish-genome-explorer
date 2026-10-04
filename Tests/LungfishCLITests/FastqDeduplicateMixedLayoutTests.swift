// FastqDeduplicateMixedLayoutTests.swift - fastq deduplicate collapses the pairs of a mixed file as pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A mixed file holds adjacent mate pairs and single (merged or orphan)
// reads. clumpify run with interleaved=f over such a file judged every
// record on its own: it dropped one mate of a pair whose other mate
// differed from its duplicate, and its reordering left no mate next to its
// partner. Measured on the base CLI with the dialog's `--pairing single`,
// with auto and with `--pairing interleaved`: 41 reads in (17 pairs and 7
// merged reads), 29 out, 0 adjacent pairs. The pairs must be deduplicated
// as pairs and the single reads as single reads, so every surviving pair
// keeps both mates next to each other (decision 1, lane A8).

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqDeduplicateMixedLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-dedup-mixed")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// 14 pairs and 7 merged reads. Pairs 10, 11 and 12 repeat pairs 0, 1
    /// and 2 exactly. Pair 13 repeats only mate 1 of pair 3, so it is not a
    /// duplicate. Merged reads 5 and 6 repeat merged reads 0 and 1.
    private func writeFixture(naming: InterleavedFASTQFixture.MateNaming, to url: URL) throws {
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 14,
            mergedCount: 7,
            naming: naming,
            sequences: { index in
                switch index {
                case 10, 11, 12:
                    return InterleavedFASTQFixture.defaultSequences(index - 10)
                case 13:
                    return (
                        InterleavedFASTQFixture.defaultSequences(3).mate1,
                        InterleavedFASTQFixture.deterministicSequence(seed: 9_999)
                    )
                default:
                    return InterleavedFASTQFixture.defaultSequences(index)
                }
            },
            mergedSequences: { index in
                InterleavedFASTQFixture.defaultMergedSequence(index >= 5 ? index - 5 : index)
            },
            to: url
        )
    }

    private struct Fragments: Equatable {
        var pairs: [[String]]
        var singles: [String]
    }

    /// The pairs (mate sequences in order) and single reads of `records`,
    /// sorted, after checking that every pair read is next to its mate.
    private func fragments(_ records: [FASTQRecord], file: StaticString = #filePath, line: UInt = #line) -> Fragments {
        InterleavedFASTQFixture.assertMixedIntegrity(records, file: file, line: line)
        var pairs: [[String]] = []
        var singles: [String] = []
        var index = 0
        while index < records.count {
            if InterleavedFASTQFixture.fragmentKey(records[index]).hasPrefix("frag"), index + 1 < records.count {
                pairs.append([records[index].sequence, records[index + 1].sequence])
                index += 2
            } else {
                singles.append(records[index].sequence)
                index += 1
            }
        }
        return Fragments(pairs: pairs.sorted { $0.joined() < $1.joined() }, singles: singles.sorted())
    }

    func testDeduplicateOnAMixedFileCollapsesPairsAsPairsAndSinglesAsSingles() async throws {
        try await requireNativeTool(.clumpify)
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let inputURL = root.appendingPathComponent("mixed-\(naming.rawValue).fastq")
            try writeFixture(naming: naming, to: inputURL)
            let input = try await InterleavedFASTQFixture.readRecords(at: inputURL)
            let inputFragments = fragments(input)
            let expected = Fragments(
                pairs: Array(Set(inputFragments.pairs)).sorted { $0.joined() < $1.joined() },
                singles: Array(Set(inputFragments.singles)).sorted()
            )
            XCTAssertEqual(expected.pairs.count, 11, "10 distinct pairs plus the half-duplicate pair")
            XCTAssertEqual(expected.singles.count, 5)

            // `--pairing interleaved` is what the dialog passes for a mixed
            // input; auto is a bare CLI call on the same file.
            for pairing in [["--pairing", "interleaved"], []] {
                let label = "\(naming.rawValue) \(pairing.joined(separator: " "))"
                let outputURL = root.appendingPathComponent("dedup-\(naming.rawValue)-\(pairing.count).fastq")
                try await FastqDeduplicateSubcommand.parse(
                    [inputURL.path, "--subs", "0", "-o", outputURL.path] + pairing
                ).run()

                let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
                XCTAssertEqual(records.count, 11 * 2 + 5, "\(label): 3 duplicate pairs and 2 duplicate merged reads removed, nothing else")
                XCTAssertEqual(fragments(records), expected, "\(label): one copy of every distinct pair and merged read, each pair whole")
            }
        }
    }

    private func requireNativeTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("\(tool.executableName) is not available in this test environment", file: file, line: line)
        }
    }
}
