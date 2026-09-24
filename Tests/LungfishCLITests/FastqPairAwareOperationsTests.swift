// FastqPairAwareOperationsTests.swift - every fastq subsetting/decontamination
// subcommand keeps interleaved mates together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Paired imports are stored as ONE interleaved FASTQ in a .lungfishfastq
// bundle whose metadata records pairingMode=interleaved, and the mates often
// carry IDENTICAL names (no /1 /2, no Casava field). The Tools menu runs
// `lungfish-cli fastq <op>` on that file. Before this fix every subcommand
// guessed pairing from names and split mates. These tests run the real
// subcommands on small fixtures for each naming style and assert:
//   - an even record count,
//   - every record directly followed by its mate,
//   - no fragment orphaned, and the expected fragments selected,
//   - --count means reads, not pairs.

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqPairAwareOperationsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-pair-aware-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Subsample

    func testSubsampleByProportionKeepsIdenticalNameMatesFromBundleMetadata() async throws {
        try await requireNativeTool(.reformat)
        // No --pairing flag: the CLI must read pairingMode from the bundle.
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "subsample", in: root, pairCount: 200, naming: .identical
        )
        let outputURL = root.appendingPathComponent("subsampled.fastq")
        let command = try FastqSubsampleSubcommand.parse([
            bundle.fastqURL.path, "--proportion", "0.5", "--seed", "42", "-o", outputURL.path,
        ])
        try await command.run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertGreaterThan(records.count, 0)
        XCTAssertLessThan(records.count, 400)
        InterleavedFASTQFixture.assertWholePairs(records)
    }

    func testSubsampleByCountReturnsTheRequestedNumberOfReadsAsWholePairs() async throws {
        try await requireNativeTool(.reformat)
        for naming in [InterleavedFASTQFixture.MateNaming.identical, .slashSuffix] {
            let inputURL = root.appendingPathComponent("count-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.write(pairCount: 200, naming: naming, to: inputURL)
            let outputURL = root.appendingPathComponent("count-\(naming.rawValue).out.fastq")
            let command = try FastqSubsampleSubcommand.parse([
                inputURL.path, "--count", "50", "--seed", "7", "--pairing", "interleaved", "-o", outputURL.path,
            ])
            try await command.run()

            let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
            XCTAssertEqual(
                records.count, 50,
                "--count 50 is a read count: 25 whole pairs, not 50 pairs (\(naming))"
            )
            InterleavedFASTQFixture.assertWholePairs(records, "\(naming)")
        }
    }

    func testSubsamplePairTargetRoundsReadCountDownToWholePairs() {
        XCTAssertEqual(FastqSubsampleSubcommand.interleavedPairTarget(forReadCount: 50), 25)
        XCTAssertEqual(FastqSubsampleSubcommand.interleavedPairTarget(forReadCount: 51), 25)
        XCTAssertEqual(FastqSubsampleSubcommand.interleavedPairTarget(forReadCount: 1), 1)
    }

    // MARK: - bbduk / clumpify filters

    func testSequenceFilterKeepsBothMatesWhenOnlyMateTwoMatches() async throws {
        try await requireNativeTool(.bbduk)
        let adapter = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
        let matchedPairs: Set<Int> = [0, 1, 2, 3, 4]
        for naming in [InterleavedFASTQFixture.MateNaming.identical, .slashSuffix] {
            let inputURL = root.appendingPathComponent("seqfilter-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.write(pairCount: 40, naming: naming, sequences: { index in
                let base = InterleavedFASTQFixture.defaultSequences(index)
                guard matchedPairs.contains(index) else { return base }
                return (base.mate1, adapter + String(base.mate2.dropFirst(adapter.count)))
            }, to: inputURL)
            let outputURL = root.appendingPathComponent("seqfilter-\(naming.rawValue).out.fastq")
            let command = try FastqSequenceFilterSubcommand.parse([
                inputURL.path, "-o", outputURL.path,
                "--sequence", adapter, "--search-end", "left", "--min-overlap", "20", "--error-rate", "0",
                "--keep-matched", "--pairing", "interleaved",
            ])
            try await command.run()

            let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
            InterleavedFASTQFixture.assertWholePairs(records, "\(naming)")
            XCTAssertEqual(records.count, matchedPairs.count * 2, "\(naming)")
            XCTAssertEqual(
                InterleavedFASTQFixture.fragmentKeys(records),
                Set(matchedPairs.map(InterleavedFASTQFixture.fragmentName)),
                "\(naming)"
            )
        }
    }

    func testEntropyFilterDropsBothMatesWhenOnlyMateTwoIsLowComplexity() async throws {
        try await requireNativeTool(.bbduk)
        let lowComplexityPairs: Set<Int> = [0, 1, 2]
        let inputURL = root.appendingPathComponent("entropy.fastq")
        try InterleavedFASTQFixture.write(pairCount: 30, naming: .identical, sequences: { index in
            let base = InterleavedFASTQFixture.defaultSequences(index)
            guard lowComplexityPairs.contains(index) else { return base }
            return (base.mate1, String(repeating: "AC", count: 30))
        }, to: inputURL)
        let outputURL = root.appendingPathComponent("entropy.out.fastq")
        let command = try FastqEntropyFilterSubcommand.parse([
            inputURL.path, "-o", outputURL.path, "--pairing", "interleaved",
        ])
        try await command.run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(records.count, (30 - lowComplexityPairs.count) * 2)
        let keys = InterleavedFASTQFixture.fragmentKeys(records)
        for index in lowComplexityPairs {
            XCTAssertFalse(keys.contains(InterleavedFASTQFixture.fragmentName(index)), "pair \(index) must be dropped whole")
        }
    }

    func testContaminantFilterDropsBothMatesWhenOnlyMateOneMatchesReference() async throws {
        try await requireNativeTool(.bbduk)
        let contaminantPairs: Set<Int> = [0, 1]
        let referenceURL = root.appendingPathComponent("contaminant.fasta")
        let referenceText = contaminantPairs.sorted().map { index in
            ">contaminant\(index)\n\(InterleavedFASTQFixture.defaultSequences(index).mate1)\n"
        }.joined()
        try referenceText.write(to: referenceURL, atomically: true, encoding: .utf8)

        let inputURL = root.appendingPathComponent("contaminant.fastq")
        try InterleavedFASTQFixture.write(pairCount: 30, naming: .identical, to: inputURL)
        let outputURL = root.appendingPathComponent("contaminant.out.fastq")
        let command = try FastqContaminantFilterSubcommand.parse([
            inputURL.path, "--mode", "custom", "--ref", referenceURL.path,
            "--kmer", "31", "--hdist", "1", "-o", outputURL.path, "--pairing", "interleaved",
        ])
        try await command.run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(records.count, (30 - contaminantPairs.count) * 2)
        let keys = InterleavedFASTQFixture.fragmentKeys(records)
        for index in contaminantPairs {
            XCTAssertFalse(keys.contains(InterleavedFASTQFixture.fragmentName(index)), "pair \(index) must be dropped whole")
        }
    }

    func testDeduplicateCollapsesWholePairsOnlyAndKeepsMatesAdjacent() async throws {
        try await requireNativeTool(.clumpify)
        // 10 unique pairs, 3 exact duplicate pairs of 0/1/2, and one pair
        // that repeats only mate 1 of pair 3. Pair-aware dedup removes the
        // three exact duplicates and must keep the half-duplicate pair.
        let inputURL = root.appendingPathComponent("dedup.fastq")
        try InterleavedFASTQFixture.write(pairCount: 14, naming: .identical, sequences: { index in
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
        }, to: inputURL)
        let outputURL = root.appendingPathComponent("dedup.out.fastq")
        let command = try FastqDeduplicateSubcommand.parse([
            inputURL.path, "--subs", "0", "-o", outputURL.path, "--pairing", "interleaved",
        ])
        try await command.run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(records.count, 11 * 2, "3 duplicate pairs removed, the half-duplicate pair kept")
        let keys = InterleavedFASTQFixture.fragmentKeys(records)
        XCTAssertTrue(keys.contains(InterleavedFASTQFixture.fragmentName(13)), "a pair whose mate 2 differs is not a duplicate")
    }

    // MARK: - seqkit searches

    func testSearchMotifExtractsBothMatesWhenOnlyMateTwoCarriesTheMotif() async throws {
        try await requireNativeTool(.seqkit)
        let motif = "GATTACAGATTACAGATTACA"
        let motifPairs: Set<Int> = [2, 7]
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let inputURL = root.appendingPathComponent("motif-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.write(pairCount: 20, naming: naming, sequences: { index in
                let base = InterleavedFASTQFixture.defaultSequences(index)
                guard motifPairs.contains(index) else { return base }
                return (base.mate1, motif + String(base.mate2.dropFirst(motif.count)))
            }, to: inputURL)
            let outputURL = root.appendingPathComponent("motif-\(naming.rawValue).out.fastq")
            let command = try FastqSearchMotifSubcommand.parse([
                inputURL.path, "-o", outputURL.path, "--pattern", motif, "--pairing", "interleaved",
            ])
            try await command.run()

            let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
            InterleavedFASTQFixture.assertWholePairs(records, "\(naming)")
            XCTAssertEqual(records.count, motifPairs.count * 2, "\(naming)")
            XCTAssertEqual(
                InterleavedFASTQFixture.fragmentKeys(records),
                Set(motifPairs.map(InterleavedFASTQFixture.fragmentName)),
                "\(naming)"
            )
        }
    }

    func testSearchMotifWithNoMatchWritesAnEmptyOutput() async throws {
        try await requireNativeTool(.seqkit)
        let inputURL = root.appendingPathComponent("motif-none.fastq")
        try InterleavedFASTQFixture.write(pairCount: 5, naming: .identical, to: inputURL)
        let outputURL = root.appendingPathComponent("motif-none.out.fastq")
        let command = try FastqSearchMotifSubcommand.parse([
            inputURL.path, "-o", outputURL.path, "--pattern", "GATTACAGATTACAGATTACAGATTACA", "--pairing", "interleaved",
        ])
        try await command.run()
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertTrue(records.isEmpty)
    }

    func testSearchTextByIDMatchesTheFragmentSoBaseNameFindsBothSlashMates() async throws {
        try await requireNativeTool(.seqkit)
        let inputURL = root.appendingPathComponent("text-id.fastq")
        try InterleavedFASTQFixture.write(pairCount: 20, naming: .slashSuffix, to: inputURL)

        let exactURL = root.appendingPathComponent("text-id-exact.out.fastq")
        try await FastqSearchTextSubcommand.parse([
            inputURL.path, "-o", exactURL.path, "--query", "frag3", "--pairing", "interleaved",
        ]).run()
        let exact = try await InterleavedFASTQFixture.readRecords(at: exactURL)
        InterleavedFASTQFixture.assertWholePairs(exact)
        XCTAssertEqual(exact.map(\.identifier), ["frag3/1", "frag3/2"])

        let regexURL = root.appendingPathComponent("text-id-regex.out.fastq")
        try await FastqSearchTextSubcommand.parse([
            inputURL.path, "-o", regexURL.path, "--query", "^frag1[0-9]$", "--regex", "--pairing", "interleaved",
        ]).run()
        let regex = try await InterleavedFASTQFixture.readRecords(at: regexURL)
        InterleavedFASTQFixture.assertWholePairs(regex)
        XCTAssertEqual(regex.count, 10 * 2)
    }

    func testSearchTextByDescriptionExtractsBothMatesWhenOnlyMateTwoMatches() async throws {
        try await requireNativeTool(.seqkit)
        // Casava mates differ only in the description ("1:N:0" vs "2:N:0").
        // A plain description query must equal the whole header, so match
        // two fragments' mate-2 headers by regex; both mates must come back.
        let inputURL = root.appendingPathComponent("text-desc.fastq")
        try InterleavedFASTQFixture.write(pairCount: 12, naming: .casava, to: inputURL)
        let outputURL = root.appendingPathComponent("text-desc.out.fastq")
        try await FastqSearchTextSubcommand.parse([
            inputURL.path, "-o", outputURL.path, "--query", "^frag[34] 2:N:0", "--regex", "--field", "description", "--pairing", "interleaved",
        ]).run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(records.count, 2 * 2)
    }

    // MARK: - Deacon (database-gated)

    func testDeaconRiboDropsBothMatesWhenOnlyMateTwoIsRibosomal() async throws {
        _ = try await ToolAvailability.require("deacon", environment: "deacon")
        try await requireNativeTool(.reformat)
        let databaseID = DeaconRibokmersDatabaseInstaller.databaseID
        _ = try await ToolAvailability.requireDatabase(
            { try? await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID) },
            name: databaseID
        )
        let ribosomalPairs: Set<Int> = [1, 4]
        let inputURL = root.appendingPathComponent("ribo.fastq")
        try InterleavedFASTQFixture.write(pairCount: 8, naming: .identical, sequences: { index in
            let base = InterleavedFASTQFixture.defaultSequences(index)
            guard ribosomalPairs.contains(index) else { return base }
            return (base.mate1, Self.ribosomalProbe)
        }, to: inputURL)
        let outputDirectory = root.appendingPathComponent("ribo-out", isDirectory: true)
        try await FastqDeaconRiboSubcommand.parse([
            inputURL.path, "--retain", "both", "--database-id", databaseID,
            "--pairing", "interleaved", "-o", outputDirectory.path,
        ]).run()

        let kept = try await InterleavedFASTQFixture.readRecords(
            at: outputDirectory.appendingPathComponent("ribo.norrna.fastq")
        )
        InterleavedFASTQFixture.assertWholePairs(kept, "norrna")
        XCTAssertEqual(kept.count, (8 - ribosomalPairs.count) * 2)
        let keptKeys = InterleavedFASTQFixture.fragmentKeys(kept)
        for index in ribosomalPairs {
            XCTAssertFalse(keptKeys.contains(InterleavedFASTQFixture.fragmentName(index)), "pair \(index) must be dropped whole")
        }

        let removed = try await InterleavedFASTQFixture.readRecords(
            at: outputDirectory.appendingPathComponent("ribo.rrna.fastq")
        )
        InterleavedFASTQFixture.assertWholePairs(removed, "rrna")
        XCTAssertEqual(
            InterleavedFASTQFixture.fragmentKeys(removed),
            Set(ribosomalPairs.map(InterleavedFASTQFixture.fragmentName))
        )
    }

    func testScrubHumanKeepsIdenticalNameMatesTogether() async throws {
        try await requireNativeTool(.deacon)
        try await requireNativeTool(.reformat)
        let databaseID = DeaconPanhumanDatabaseInstaller.databaseID
        _ = try await ToolAvailability.requireDatabase(
            { try? await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID) },
            name: databaseID
        )
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "scrub", in: root, pairCount: 10, naming: .identical
        )
        let outputURL = root.appendingPathComponent("scrubbed.fastq")
        try await FastqScrubHumanSubcommand.parse([
            bundle.fastqURL.path, "-o", outputURL.path, "--database-id", databaseID,
        ]).run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(records.count, 10 * 2, "synthetic reads are not human; every pair survives intact")
    }

    // MARK: - Helpers

    /// 125 bp from the first record of BBMap's ribokmers reference.
    private static let ribosomalProbe =
        "GTCGGAACTTACCCGACAAGGAATTTCGCTCACCCTTATCCCACCCTTTCGGAGTGGGGGTGGACTGTAT"
        + "CTTCATCCAGTCCCCGGATCTCTTCGAGGGTTCGTTTCAACCTTTCGTGGTTTCC"

    private func requireNativeTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("\(tool.executableName) is not available in this test environment", file: file, line: line)
        }
    }
}
