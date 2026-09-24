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

import ArgumentParser
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

    // MARK: - Mixed input (merged single reads between pairs)
    //
    // The VSP2 and Illumina Amplicon Merge recipes leave one file holding
    // merged reads AND unmerged pairs, and the bundle records
    // pairingMode=interleaved. A positional tool (`interleaved=t`, an R1/R2
    // split) pairs a merged read with the next mate. Owner contract: such a
    // file runs as single reads unless the operation pairs by name.

    func testSubsampleTreatsAMixedBundleAsSingleReadsEvenWhenToldInterleaved() async throws {
        try await requireNativeTool(.seqkit)
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "mixed-subsample", in: root, pairCount: 40, mergedCount: 21, naming: .identical
        )
        let input = try await InterleavedFASTQFixture.readRecords(at: bundle.fastqURL)
        // --pairing interleaved is what the GUI passes from the bundle's
        // pairingMode; auto reads the same metadata. Both must be verified
        // against the records and fall back to single reads.
        for pairing in [["--pairing", "interleaved"], []] {
            let outputURL = root.appendingPathComponent("mixed-subsample-\(pairing.count).fastq")
            try await FastqSubsampleSubcommand.parse(
                [bundle.fastqURL.path, "--count", "33", "--seed", "3", "-o", outputURL.path] + pairing
            ).run()
            let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
            XCTAssertEqual(records.count, 33, "--count is a read count on single reads; a positional pair sampler would return an even count (\(pairing))")
            XCTAssertTrue(
                Self.isSubsequence(records.map(\.identifier), of: input.map(\.identifier)),
                "records come back in input order, untouched (\(pairing))"
            )
        }
    }

    func testSubsampleStillKeepsWholePairsOnAStrictBundle() async throws {
        try await requireNativeTool(.reformat)
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "strict-subsample", in: root, pairCount: 40, naming: .identical
        )
        let outputURL = root.appendingPathComponent("strict-subsample.fastq")
        try await FastqSubsampleSubcommand.parse(
            [bundle.fastqURL.path, "--count", "20", "--seed", "3", "-o", outputURL.path]
        ).run()
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertEqual(records.count, 20)
        InterleavedFASTQFixture.assertWholePairs(records)
    }

    func testSequenceFilterOnAMixedFileKeepsExactlyTheMatchingRecords() async throws {
        try await requireNativeTool(.bbduk)
        let adapter = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
        // The adapter sits in mate 2 of pairs 1 and 3 and in merged reads 0 and 2.
        let inputURL = root.appendingPathComponent("mixed-seqfilter.fastq")
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 10, mergedCount: 4, naming: .identical,
            sequences: { index in
                let base = InterleavedFASTQFixture.defaultSequences(index)
                guard [1, 3].contains(index) else { return base }
                return (base.mate1, adapter + String(base.mate2.dropFirst(adapter.count)))
            },
            mergedSequences: { index in
                let base = InterleavedFASTQFixture.defaultMergedSequence(index)
                guard [0, 2].contains(index) else { return base }
                return adapter + String(base.dropFirst(adapter.count))
            },
            to: inputURL
        )
        let outputURL = root.appendingPathComponent("mixed-seqfilter.out.fastq")
        try await FastqSequenceFilterSubcommand.parse([
            inputURL.path, "-o", outputURL.path,
            "--sequence", adapter, "--search-end", "left", "--min-overlap", "20", "--error-rate", "0",
            "--keep-matched", "--pairing", "interleaved",
        ]).run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        // Single-read handling keeps the four matching records and nothing
        // else. Positional pairing would have dragged a merged read's
        // neighbour along and split the matched pairs differently.
        // Input order is frag0, frag0, merged0, frag1, frag1, merged1, ...
        XCTAssertEqual(
            records.map(\.identifier),
            ["merged0", "frag1", "merged2", "frag3"],
            "only the records that carry the adapter, in input order"
        )
    }

    func testEntropyFilterOnAMixedFileDropsOnlyTheLowComplexityRecords() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("mixed-entropy.fastq")
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 12, mergedCount: 5, naming: .slashSuffix,
            sequences: { index in
                let base = InterleavedFASTQFixture.defaultSequences(index)
                guard index == 2 else { return base }
                return (base.mate1, String(repeating: "AC", count: 30))
            },
            mergedSequences: { index in
                index == 1 ? String(repeating: "GT", count: 50) : InterleavedFASTQFixture.defaultMergedSequence(index)
            },
            to: inputURL
        )
        let outputURL = root.appendingPathComponent("mixed-entropy.out.fastq")
        try await FastqEntropyFilterSubcommand.parse([
            inputURL.path, "-o", outputURL.path, "--pairing", "interleaved",
        ]).run()

        let input = try await InterleavedFASTQFixture.readRecords(at: inputURL)
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        let expected = input.map(\.identifier).filter { $0 != "frag2/2" && $0 != "merged1" }
        XCTAssertEqual(records.map(\.identifier), expected, "only the two low-complexity records are dropped; frag2/1 survives alone as a single read")
    }

    func testContaminantFilterOnAMixedFileDropsOnlyTheMatchingRecords() async throws {
        try await requireNativeTool(.bbduk)
        let referenceURL = root.appendingPathComponent("mixed-contaminant.fasta")
        try ">contaminant0\n\(InterleavedFASTQFixture.defaultSequences(0).mate1)\n>contaminant1\n\(InterleavedFASTQFixture.defaultMergedSequence(1))\n"
            .write(to: referenceURL, atomically: true, encoding: .utf8)
        // /1 /2 names: BBTools' own detection would pair them by position,
        // and distinct identifiers let the test name the dropped mate.
        let inputURL = root.appendingPathComponent("mixed-contaminant.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 10, mergedCount: 4, naming: .slashSuffix, to: inputURL)
        let outputURL = root.appendingPathComponent("mixed-contaminant.out.fastq")
        try await FastqContaminantFilterSubcommand.parse([
            inputURL.path, "--mode", "custom", "--ref", referenceURL.path,
            "--kmer", "31", "--hdist", "0", "-o", outputURL.path, "--pairing", "interleaved",
        ]).run()

        let input = try await InterleavedFASTQFixture.readRecords(at: inputURL)
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        let dropped = Set(input.map(\.identifier)).subtracting(records.map(\.identifier))
        XCTAssertEqual(dropped, ["frag0/1", "merged1"], "mate 1 of pair 0 and merged read 1 match the reference; nothing else is dragged along")
        XCTAssertEqual(records.count, input.count - 2)
        XCTAssertEqual(records.map(\.identifier), input.map(\.identifier).filter { $0 != "frag0/1" && $0 != "merged1" }, "input order is kept")
    }

    func testDeduplicateOnAMixedFileCollapsesRecordsNotPositionalPairs() async throws {
        try await requireNativeTool(.clumpify)
        // Merged read 2 duplicates merged read 0; pair 5 duplicates pair 1.
        let inputURL = root.appendingPathComponent("mixed-dedup.fastq")
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 8, mergedCount: 4, naming: .identical,
            sequences: { index in InterleavedFASTQFixture.defaultSequences(index == 5 ? 1 : index) },
            mergedSequences: { index in InterleavedFASTQFixture.defaultMergedSequence(index == 2 ? 0 : index) },
            to: inputURL
        )
        let outputURL = root.appendingPathComponent("mixed-dedup.out.fastq")
        try await FastqDeduplicateSubcommand.parse([
            inputURL.path, "--subs", "0", "-o", outputURL.path, "--pairing", "interleaved",
        ]).run()

        let input = try await InterleavedFASTQFixture.readRecords(at: inputURL)
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertEqual(Set(records.map(\.sequence)), Set(input.map(\.sequence)), "every distinct sequence survives")
        XCTAssertEqual(records.count, Set(input.map(\.sequence)).count, "exactly one copy of each sequence remains")
    }

    func testSearchMotifOnAMixedFileReturnsWholePairsAndLoneMergedReads() async throws {
        try await requireNativeTool(.seqkit)
        let motif = "GATTACAGATTACAGATTACA"
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let inputURL = root.appendingPathComponent("mixed-motif-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.writeMixed(
                pairCount: 10, mergedCount: 5, naming: naming,
                sequences: { index in
                    let base = InterleavedFASTQFixture.defaultSequences(index)
                    guard [2, 7].contains(index) else { return base }
                    return (base.mate1, motif + String(base.mate2.dropFirst(motif.count)))
                },
                mergedSequences: { index in
                    let base = InterleavedFASTQFixture.defaultMergedSequence(index)
                    guard index == 3 else { return base }
                    return motif + String(base.dropFirst(motif.count))
                },
                to: inputURL
            )
            let outputURL = root.appendingPathComponent("mixed-motif-\(naming.rawValue).out.fastq")
            try await FastqSearchMotifSubcommand.parse([
                inputURL.path, "-o", outputURL.path, "--pattern", motif, "--pairing", "interleaved",
            ]).run()

            let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
            InterleavedFASTQFixture.assertMixedIntegrity(records, "\(naming)")
            XCTAssertEqual(
                records.map(InterleavedFASTQFixture.fragmentKey),
                ["frag2", "frag2", "merged3", "frag7", "frag7"],
                "\(naming): both mates of a matching pair, the matching merged read alone, in input order"
            )
        }
    }

    func testSearchTextByIDOnAMixedFileReturnsBothMatesAndLoneMergedReads() async throws {
        try await requireNativeTool(.seqkit)
        let inputURL = root.appendingPathComponent("mixed-text.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 12, mergedCount: 3, naming: .slashSuffix, to: inputURL)
        let outputURL = root.appendingPathComponent("mixed-text.out.fastq")
        try await FastqSearchTextSubcommand.parse([
            inputURL.path, "-o", outputURL.path, "--query", "^(frag1|merged1)$", "--regex",
        ]).run()
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertMixedIntegrity(records)
        XCTAssertEqual(records.map(\.identifier), ["frag1/1", "frag1/2", "merged1"])
    }

    func testDeinterleaveOnAMixedFileSplitsByNameIntoThreeOutputs() async throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let inputURL = root.appendingPathComponent("mixed-deint-\(naming.rawValue).fastq")
            try InterleavedFASTQFixture.writeMixed(pairCount: 7, mergedCount: 3, naming: naming, to: inputURL)
            let out1 = root.appendingPathComponent("mixed-deint-\(naming.rawValue)-R1.fastq")
            let out2 = root.appendingPathComponent("mixed-deint-\(naming.rawValue)-R2.fastq")
            let unpaired = root.appendingPathComponent("mixed-deint-\(naming.rawValue)-unpaired.fastq")
            try await FastqDeinterleaveSubcommand.parse([
                inputURL.path, "--out1", out1.path, "--out2", out2.path, "--unpaired", unpaired.path,
            ]).run()

            let mates1 = try await InterleavedFASTQFixture.readRecords(at: out1)
            let mates2 = try await InterleavedFASTQFixture.readRecords(at: out2)
            let singles = try await InterleavedFASTQFixture.readRecords(at: unpaired)
            XCTAssertEqual(mates1.map(InterleavedFASTQFixture.fragmentKey), (0..<7).map(InterleavedFASTQFixture.fragmentName), "\(naming)")
            XCTAssertEqual(mates2.map(InterleavedFASTQFixture.fragmentKey), (0..<7).map(InterleavedFASTQFixture.fragmentName), "\(naming)")
            XCTAssertEqual(mates1.map(\.sequence), (0..<7).map { InterleavedFASTQFixture.defaultSequences($0).mate1 }, "\(naming)")
            XCTAssertEqual(mates2.map(\.sequence), (0..<7).map { InterleavedFASTQFixture.defaultSequences($0).mate2 }, "\(naming)")
            XCTAssertEqual(singles.map(\.identifier), (0..<3).map(InterleavedFASTQFixture.mergedName), "\(naming)")
        }
    }

    func testDeinterleaveOnAMixedFileWithoutUnpairedOutputRefusesClearly() async throws {
        let inputURL = root.appendingPathComponent("mixed-deint-refuse.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 4, mergedCount: 2, naming: .identical, to: inputURL)
        let out1 = root.appendingPathComponent("refuse-R1.fastq")
        let out2 = root.appendingPathComponent("refuse-R2.fastq")
        do {
            try await FastqDeinterleaveSubcommand.parse([inputURL.path, "--out1", out1.path, "--out2", out2.path]).run()
            XCTFail("A mixed file must not be split by position")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--unpaired"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out2.path))
    }

    func testDeinterleaveRefusesASingleEndFile() async throws {
        let inputURL = root.appendingPathComponent("single-deint.fastq")
        try (0..<6).map { "@read\($0)\nACGTACGTAC\n+\nIIIIIIIIII" }.joined(separator: "\n").appending("\n")
            .write(to: inputURL, atomically: true, encoding: .utf8)
        do {
            try await FastqDeinterleaveSubcommand.parse([
                inputURL.path, "--out1", root.appendingPathComponent("s1.fastq").path, "--out2", root.appendingPathComponent("s2.fastq").path,
            ]).run()
            XCTFail("A single-end file has nothing to deinterleave")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("not interleaved"), error.message)
        }
    }

    func testDeinterleaveOnAStrictFileStillSplitsByPosition() async throws {
        try await requireNativeTool(.reformat)
        let inputURL = root.appendingPathComponent("strict-deint.fastq")
        try InterleavedFASTQFixture.write(pairCount: 9, naming: .identical, to: inputURL)
        let out1 = root.appendingPathComponent("strict-R1.fastq")
        let out2 = root.appendingPathComponent("strict-R2.fastq")
        try await FastqDeinterleaveSubcommand.parse([inputURL.path, "--out1", out1.path, "--out2", out2.path]).run()
        let mates1 = try await InterleavedFASTQFixture.readRecords(at: out1)
        let mates2 = try await InterleavedFASTQFixture.readRecords(at: out2)
        XCTAssertEqual(mates1.map(\.sequence), (0..<9).map { InterleavedFASTQFixture.defaultSequences($0).mate1 })
        XCTAssertEqual(mates2.map(\.sequence), (0..<9).map { InterleavedFASTQFixture.defaultSequences($0).mate2 })
    }

    /// Mates that overlap by 50 bases, so bbmerge joins every pair.
    private static let overlappingMates: InterleavedFASTQFixture.PairSequences = { index in
        let insert = InterleavedFASTQFixture.deterministicSequence(seed: 500 + UInt64(index), length: 150)
        let mate1 = String(insert.prefix(100))
        let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
        let mate2 = String(insert.suffix(100).reversed().map { complement[$0] ?? "N" })
        return (mate1, mate2)
    }

    func testMergeOnAMixedFileMergesOnlyThePairsAndPassesMergedReadsThrough() async throws {
        try await requireNativeTool(.bbmerge)
        let inputURL = root.appendingPathComponent("mixed-merge.fastq")
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 8, mergedCount: 5, naming: .casava, sequences: Self.overlappingMates, to: inputURL
        )
        let outputURL = root.appendingPathComponent("mixed-merge.out.fastq")
        try await FastqMergeSubcommand.parse([inputURL.path, "-o", outputURL.path]).run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        let passthrough = records.filter { $0.identifier.hasPrefix("merged") }
        XCTAssertEqual(passthrough.map(\.identifier), (0..<5).map(InterleavedFASTQFixture.mergedName), "merged reads pass through in order")
        XCTAssertEqual(passthrough.map(\.sequence), (0..<5).map(InterleavedFASTQFixture.defaultMergedSequence), "merged reads are untouched")
        let fromPairs = records.filter { $0.identifier.hasPrefix("frag") }
        XCTAssertEqual(Set(fromPairs.map(InterleavedFASTQFixture.fragmentKey)), Set((0..<8).map(InterleavedFASTQFixture.fragmentName)))
        XCTAssertEqual(fromPairs.count, 8, "every overlapping pair becomes one merged record")
        XCTAssertTrue(fromPairs.allSatisfy { $0.sequence.count == 150 }, "a merged pair spans the 150-base insert")
    }

    func testMergeOnAStrictFileWithIdenticalMateNamesMergesEveryPair() async throws {
        try await requireNativeTool(.bbmerge)
        let inputURL = root.appendingPathComponent("strict-merge.fastq")
        try InterleavedFASTQFixture.write(pairCount: 6, naming: .identical, sequences: Self.overlappingMates, to: inputURL)
        let outputURL = root.appendingPathComponent("strict-merge.out.fastq")
        try await FastqMergeSubcommand.parse([inputURL.path, "-o", outputURL.path]).run()
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertEqual(records.count, 6, "interleaved=t pairs identical-name mates that bbmerge's own detection ignores")
        XCTAssertTrue(records.allSatisfy { $0.sequence.count == 150 })
    }

    func testMergeRefusesASingleEndFile() async throws {
        let inputURL = root.appendingPathComponent("single-merge.fastq")
        try (0..<4).map { "@read\($0)\nACGTACGTAC\n+\nIIIIIIIIII" }.joined(separator: "\n").appending("\n")
            .write(to: inputURL, atomically: true, encoding: .utf8)
        do {
            try await FastqMergeSubcommand.parse([inputURL.path, "-o", root.appendingPathComponent("no.fastq").path]).run()
            XCTFail("Nothing to merge in a single-end file")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("no interleaved pairs"), error.message)
        }
    }

    func testDeaconRiboOnAMixedFileJudgesEachRecordAlone() async throws {
        _ = try await ToolAvailability.require("deacon", environment: "deacon")
        let databaseID = DeaconRibokmersDatabaseInstaller.databaseID
        _ = try await ToolAvailability.requireDatabase(
            { try? await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID) },
            name: databaseID
        )
        let inputURL = root.appendingPathComponent("mixed-ribo.fastq")
        try InterleavedFASTQFixture.writeMixed(
            pairCount: 6, mergedCount: 3, naming: .identical,
            sequences: { index in
                let base = InterleavedFASTQFixture.defaultSequences(index)
                return index == 1 ? (base.mate1, Self.ribosomalProbe) : base
            },
            mergedSequences: { index in index == 0 ? Self.ribosomalProbe : InterleavedFASTQFixture.defaultMergedSequence(index) },
            to: inputURL
        )
        let outputDirectory = root.appendingPathComponent("mixed-ribo-out", isDirectory: true)
        try await FastqDeaconRiboSubcommand.parse([
            inputURL.path, "--retain", "both", "--database-id", databaseID,
            "--pairing", "interleaved", "-o", outputDirectory.path,
        ]).run()

        let removed = try await InterleavedFASTQFixture.readRecords(
            at: outputDirectory.appendingPathComponent("mixed-ribo.rrna.fastq")
        )
        // Input order is frag0, frag0, merged0, frag1, frag1, ...
        XCTAssertEqual(removed.map(\.identifier), ["merged0", "frag1"], "only the two ribosomal records, judged alone; frag1's mate 1 stays")
        let kept = try await InterleavedFASTQFixture.readRecords(
            at: outputDirectory.appendingPathComponent("mixed-ribo.norrna.fastq")
        )
        XCTAssertEqual(kept.count, 6 * 2 + 3 - 2)
    }

    // MARK: - Helpers

    /// Whether `candidate` appears in `sequence` in order (not necessarily contiguously).
    private static func isSubsequence(_ candidate: [String], of sequence: [String]) -> Bool {
        var index = sequence.startIndex
        for item in candidate {
            guard let found = sequence[index...].firstIndex(of: item) else { return false }
            index = sequence.index(after: found)
        }
        return true
    }

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
