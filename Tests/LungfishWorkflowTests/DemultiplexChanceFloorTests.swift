// DemultiplexChanceFloorTests.swift - BIO's chance floor of a search of the read bases (L5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN item 3. A search of the read bases for a bare 8-base index at -e 0.15 gives about 0.93%
// of reads that carry no barcode one of the default kit's 12 (BIO, `S33-R1-BIO.md:43`), and the run published
// those chance matches as samples.
//
// Phase 3.3 lane DEMUXNULL (BIO-DEMUX-NULL, blocker B1 of the floor review). Real read starts are not uniform, so the
// floor of uniform random bases passed chance matches as samples on 61 of 87 cuts of 16 public runs. The tests of the
// last section hold the null to the file's own read starts. Their reads are the first 12 bases of real mate-1 reads, kept
// in `Tests/Fixtures/demux-null/`, and no file carries the default kit, so every barcode that beats the floor is false.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexChanceFloorTests: XCTestCase {
    private let kit = BarcodeKitRegistry.truseqSingleA

    private var defaultKitPatterns: [String: [String]] {
        Dictionary(uniqueKeysWithValues: kit.barcodes.map { ($0.id, ["^\($0.i7Sequence)"]) })
    }

    func testDefaultKitChanceShareMatchesBIOsModel() {
        var total = 0.0
        for (barcode, lines) in defaultKitPatterns {
            let share = DemultiplexChanceFloor.chanceProbability(ofLines: lines, errorRate: 0.15, allowsIndels: true)
            XCTAssertGreaterThan(share, 0.0005, barcode)
            XCTAssertLessThan(share, 0.0010, barcode)
            total += share
        }
        XCTAssertGreaterThan(total, 0.0085, "BIO's exact share is 0.932%")
        XCTAssertLessThan(total, 0.0100, "BIO's exact share is 0.932%")
        print("DEMUXRUN default kit chance share at -e 0.15: \(total)")
        XCTAssertEqual(DemultiplexChanceFloor.anchoredMatchProbability(Array(repeating: 0, count: 4), errors: 0, allowsIndels: true), 1.0 / 256)
    }

    func testChanceOnlyCountsBeatNoFloorAndARealSampleDoes() {
        let chance = Dictionary(uniqueKeysWithValues: kit.barcodes.map { ($0.id, 12) })
        let none = DemultiplexChanceFloor.evaluate(
            patterns: defaultKitPatterns, counts: chance, readsSearched: 10_000,
            unassigned: 10_000 - chance.values.reduce(0, +), errorRate: 0.15, allowsIndels: true,
            pairedFragments: false
        )
        XCTAssertFalse(none.anyBarcodeBeatsTheFloor, "\(none.barcodes)")
        var real = chance
        real["D701"] = 80
        let one = DemultiplexChanceFloor.evaluate(
            patterns: defaultKitPatterns, counts: real, readsSearched: 10_000,
            unassigned: 10_000 - chance.values.reduce(0, +), errorRate: 0.15, allowsIndels: true,
            pairedFragments: false
        )
        XCTAssertTrue(one.anyBarcodeBeatsTheFloor)
        XCTAssertEqual(one.barcodesWithinChance.count, 11, "the other barcodes keep their outputs and are named")
    }

    /// QA's case (L5): an even 384-sample inline pool with 4-base barcodes keeps every real sample. 384 distinct
    /// barcodes cannot all be 4 bases (there are 256), so the pool takes 192 of 4 bases and 192 of 5, prefix free,
    /// as a GBS key mixes lengths, at 100 reads a sample.
    /// BIO-DEMUX-FLOOR item 6: chance matches come only from reads with no barcode, so with none unassigned no sample
    /// is named within chance, and 1,920 random reads added (about 120 left unassigned) name none either.
    func testEven384SampleInlinePoolWithFourAndFiveBaseBarcodesKeepsEverySample() {
        let letters = Array("ACGT")
        let fours = (0..<256).map { value in String((0..<4).map { letters[(value >> (2 * (3 - $0))) & 3] }) }
        let shortBarcodes = Array(fours.prefix(192))
        let longBarcodes = Array(fours.suffix(64).flatMap { prefix in letters.map { prefix + String($0) } }.prefix(192))
        let barcodes = shortBarcodes + longBarcodes
        XCTAssertEqual(Set(barcodes).count, 384)
        let patterns = Dictionary(uniqueKeysWithValues: barcodes.map { ($0, ["^\($0)"]) })
        let counts = Dictionary(uniqueKeysWithValues: barcodes.map { ($0, 100) })
        let outcome = DemultiplexChanceFloor.evaluate(
            patterns: patterns, counts: counts, readsSearched: 38_400, unassigned: 0, errorRate: 0.15, allowsIndels: true,
            pairedFragments: false
        )
        XCTAssertTrue(outcome.anyBarcodeBeatsTheFloor, "the run publishes, so every sample keeps its output")
        XCTAssertEqual(outcome.barcodes.count, 384)
        XCTAssertEqual(outcome.chanceTrials, 0)
        XCTAssertEqual(outcome.barcodesWithinChance, [], "no read was left to be a chance match")

        // Each random read takes the barcode its first bases spell, since -e 0.15 allows no error on 4 or 5 bases.
        var generator = DemuxFloorSeededGenerator(seed: 7)
        var mixedCounts = counts
        var unassigned = 0
        let barcodeSet = Set(barcodes)
        for _ in 0..<1_920 {
            let read = DemuxFloorFixtures.randomBases(5, using: &generator)
            if barcodeSet.contains(String(read.prefix(4))) {
                mixedCounts[String(read.prefix(4)), default: 0] += 1
            } else if barcodeSet.contains(read) {
                mixedCounts[read, default: 0] += 1
            } else {
                unassigned += 1
            }
        }
        let mixed = DemultiplexChanceFloor.evaluate(
            patterns: patterns, counts: mixedCounts, readsSearched: 38_400 + 1_920, unassigned: unassigned,
            errorRate: 0.15, allowsIndels: true, pairedFragments: false
        )
        XCTAssertTrue(mixed.anyBarcodeBeatsTheFloor)
        XCTAssertEqual(mixed.barcodesWithinChance, [], "trials \(mixed.chanceTrials) from \(unassigned) unassigned")
        print("DEMUXRUN 384 pool plus 1,920 random reads: \(unassigned) unassigned, \(mixed.chanceTrials) chance trials")
    }

    /// DEMUXFLOOR-UX SF3: the floor also guards a Custom Definition, so its next step names one.
    func testNoBarcodeAboveChanceWordsOfferTheCustomDefinitionWayOut() throws {
        let words = try XCTUnwrap(DemultiplexError.noBarcodeAboveChance(kitName: "K").errorDescription)
        XCTAssertTrue(words.hasPrefix(
            "No barcode of K matched more reads than chance alone gives, so Demultiplex Barcodes made no sample files."
        ), words)
        XCTAssertTrue(words.contains("already be split into one file per sample"), words)
        XCTAssertTrue(words.hasSuffix(
            "Choose the kit the library was made with, check the barcode sequences and the end of the read you chose "
                + "for a Custom Definition, or import this file as one sample."
        ), words)
    }

    /// DEMUXFLOOR-UX SF3: the header refusal keeps UX's words of `S33-R2-UX.md:41` whole.
    func testReadNameIndexRefusalSaysWhatHappenedAndTheNextStep() {
        XCTAssertEqual(
            DemultiplexError.readNameIndexNotSplitYet.errorDescription,
            "These reads carry their index in the read names. Demultiplex Barcodes searches the read sequences and "
                + "cannot split them by that index yet, so it did not start and wrote no files. Get one FASTQ file per "
                + "sample, as bcl2fastq or BCL Convert writes them from the run's sample sheet, and import those."
        )
    }

    // MARK: - The null measured on the file's own read starts (BIO-DEMUX-NULL item 8)

    private let errorRate = 0.15

    private func fixtureStarts(_ name: String) throws -> [String] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/demux-null/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The floor on a file whose read starts are `starts`. Each default-kit barcode counts its matches with the floor's own
    /// anchored matcher, the reads that match none are the unassigned reads, and their first bases give the null.
    private func outcome(ofStarts starts: [String]) -> DemultiplexChanceFloor.Outcome {
        let neighbours = kit.barcodes.map { barcode -> (id: String, ball: DemultiplexChanceFloor.AnchoredNeighbours) in
            let bases = DemultiplexChanceFloor.baseCodes(barcode.i7Sequence)
            let errors = DemultiplexChanceFloor.allowedErrors(length: bases.count, errorRate: errorRate)
            return (barcode.id, .init(pattern: bases, errors: errors, allowsIndels: true))
        }
        var counts: [String: Int] = [:]
        var tally = DemultiplexChanceFloor.StartTally(
            windowLength: DemultiplexChanceFloor.startWindowLength(patterns: defaultKitPatterns, errorRate: errorRate)
        )
        var unassigned = 0
        for start in starts {
            let codes = DemultiplexChanceFloor.baseCodes(start)
            let hits = neighbours.filter { $0.ball.matches(codes) }
            for hit in hits { counts[hit.id, default: 0] += 1 }
            if hits.isEmpty {
                unassigned += 1
                tally.add(codes: codes)
            }
        }
        return DemultiplexChanceFloor.evaluate(
            patterns: defaultKitPatterns, counts: counts, readsSearched: starts.count, unassigned: unassigned,
            errorRate: errorRate, allowsIndels: true, pairedFragments: false, unassignedStarts: [tally]
        )
    }

    private func beating(_ outcome: DemultiplexChanceFloor.Outcome) -> [String] {
        outcome.barcodes.filter(\.beatsTheFloor).map(\.barcodeID).sorted()
    }

    /// `count` reads that start with D701 (ATTACTCG) and go on with the bases 9 to 12 of the first source reads.
    private func lonelySample(of count: Int, from starts: [String]) -> [String] {
        starts.prefix(count).map { "ATTACTCG" + $0.dropFirst(8) }
    }

    /// The reviewer's test (`DEMUXFLOOR-BIO.md:36`): counts at the chance of the real E. coli starts, which sit up to 2.95 times
    /// the uniform chance, never beat the floor from 10^4 to 10^7 reads, and a lone sample of 1% still does.
    func testPureChanceCountsOfRealReadStartsNeverBeatTheFloorAtRealRunSizes() {
        let startComposition: [[Double]] = [
            [22.1, 26.1, 38.0, 13.7], [19.8, 27.3, 16.3, 36.6], [24.7, 25.8, 20.8, 28.6],
            [18.0, 31.8, 14.4, 35.8], [33.3, 16.5, 14.9, 35.3], [35.0, 15.5, 31.3, 18.2],
            [29.5, 22.7, 25.5, 22.3], [34.1, 21.7, 24.9, 19.3], [16.4, 39.3, 23.7, 20.6],
        ].map { $0.map { $0 / 100 } }
        let ratio = [
            "D701": 0.86, "D702": 0.43, "D703": 0.84, "D704": 0.87, "D705": 2.95, "D706": 1.37,
            "D707": 0.82, "D708": 0.31, "D709": 1.10, "D710": 0.48, "D711": 0.42, "D712": 0.71,
        ]
        for reads in [10_000, 100_000, 1_000_000, 10_000_000] {
            var counts: [String: Int] = [:]
            for barcode in kit.barcodes {
                let share = DemultiplexChanceFloor.chanceProbability(
                    ofLines: ["^\(barcode.i7Sequence)"], errorRate: errorRate, allowsIndels: true
                )
                counts[barcode.id] = Int((Double(reads) * share * (ratio[barcode.id] ?? 1)).rounded())
            }
            let none = DemultiplexChanceFloor.evaluate(
                patterns: defaultKitPatterns, counts: counts, readsSearched: reads,
                unassigned: reads - counts.values.reduce(0, +), errorRate: errorRate, allowsIndels: true,
                pairedFragments: false, startComposition: startComposition, margin: 2
            )
            XCTAssertFalse(none.anyBarcodeBeatsTheFloor, "\(reads) reads, beating: \(beating(none))")
            var real = counts
            real["D701"] = reads / 100
            let one = DemultiplexChanceFloor.evaluate(
                patterns: defaultKitPatterns, counts: real, readsSearched: reads,
                unassigned: reads - real.values.reduce(0, +), errorRate: errorRate, allowsIndels: true,
                pairedFragments: false, startComposition: startComposition, margin: 2
            )
            XCTAssertTrue(one.anyBarcodeBeatsTheFloor, "\(reads) reads with a lone sample of 1%")
        }
    }

    func testRealShotgunStartsWithNoBarcodeNeverBeatTheFloor() throws {
        let starts = try fixtureStarts("SRR2584863-R1-first100000-starts12.txt")
        XCTAssertEqual(starts.count, 100_000)
        XCTAssertEqual(beating(outcome(ofStarts: starts)), [], "E. coli shotgun reads carry no barcode")
        let sample = outcome(ofStarts: starts + lonelySample(of: 1_000, from: starts))
        XCTAssertEqual(beating(sample), ["D701"], "a lone sample of 1% beats the floor and no chance count does")
    }

    func testRealNextSeqStartsWithNoBarcodeNeverBeatTheFloor() throws {
        let starts = try fixtureStarts("SRR41594715-R1-first10000-starts12.txt")
        XCTAssertEqual(starts.count, 10_000)
        XCTAssertEqual(beating(outcome(ofStarts: starts)), [], "NextSeq 2000 reads carry no barcode")
        let sample = outcome(ofStarts: starts + lonelySample(of: 100, from: starts))
        XCTAssertEqual(beating(sample), ["D701"], "a lone sample of 1% beats the floor and no chance count does")
    }

    /// An amplicon file's starts repeat, so the margin measured on decoys is large (22 to 25 in the made measure) and asks a
    /// lone sample for more than 1%. The run refuses in the floor's words, which is right for a file whose own starts vary so much.
    func testRealAmpliconStartsWithNoBarcodeNeverBeatTheFloor() throws {
        let starts = try fixtureStarts("SRR36291587-R1-first10000-starts12.txt")
        XCTAssertEqual(starts.count, 10_000)
        XCTAssertEqual(beating(outcome(ofStarts: starts)), [], "QIAseq amplicon reads carry no barcode")
        let sample = outcome(ofStarts: starts + lonelySample(of: 100, from: starts))
        XCTAssertEqual(beating(sample), [], "the margin of an amplicon file asks a lone sample for more than 1%")
        XCTAssertNotNil(DemultiplexError.noBarcodeAboveChance(kitName: kit.displayName).errorDescription)
    }

    /// The first ruling's case, re-ruled: 50 reads of D701 among 10,000 random reads still beat the floor.
    func testFiftyRealReadsInTenThousandRandomReadsStillBeatTheFloor() {
        for seed in 1_000..<1_100 {
            var generator = DemuxFloorSeededGenerator(seed: UInt64(seed))
            var starts = (0..<10_000).map { _ in DemuxFloorFixtures.randomBases(40, using: &generator) }
            starts += (0..<50).map { _ in "ATTACTCG" + DemuxFloorFixtures.randomBases(32, using: &generator) }
            let result = outcome(ofStarts: starts)
            XCTAssertTrue(beating(result).contains("D701"), "seed \(seed), beating: \(beating(result))")
        }
    }
}
