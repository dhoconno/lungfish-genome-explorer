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
        // DEMUXNULL-UX SF3: the measured floor adds a fourth cause, a real barcode on too small a share of the reads.
        XCTAssertTrue(words.contains("too few reads to stand above chance"), words)
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
        var tally = DemultiplexChanceFloor.StartTally(patterns: defaultKitPatterns, errorRate: errorRate, allowsIndels: true)
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

    /// The first ruling's case, re-ruled: 50 reads of D701 among 10,000 random reads still beat the floor. BIO measured 100 of
    /// 100 seeds with 500 decoys. The margin of random reads is 2 unless a decoy holds more reads than chance gives it at twice
    /// its share (BIO-DEMUX-SPARSE-MARGIN: 2 in 5 of 5 seeds at 10^4), so a miss is rare. The test allows 3 misses of 100 and
    /// names them.
    func testFiftyRealReadsInTenThousandRandomReadsStillBeatTheFloor() {
        var missed: [Int] = []
        for seed in 1_000..<1_100 {
            var generator = DemuxFloorSeededGenerator(seed: UInt64(seed))
            var starts = (0..<10_000).map { _ in DemuxFloorFixtures.randomBases(40, using: &generator) }
            starts += (0..<50).map { _ in "ATTACTCG" + DemuxFloorFixtures.randomBases(32, using: &generator) }
            if !beating(outcome(ofStarts: starts)).contains("D701") { missed.append(seed) }
        }
        XCTAssertLessThanOrEqual(missed.count, 3, "seeds where the lone sample of 0.5% did not beat the floor: \(missed)")
    }

    // MARK: - Paired runs (BIO-DEMUX-NULL item 7)

    /// The unassigned file of a run that places mates keeps the input's order, a pair's mates side by side, and a read with no
    /// mate beside it stands alone (`DemultiplexingPipeline+MateAssignment.swift`). The floor tallies mate 1 and mate 2 apart by
    /// the same rule, so a single read in the file never moves the mates that follow it.
    func testPairedUnassignedStartsAreTalliedByMateAndASingleReadIsLeftOut() async throws {
        var text = ""
        func add(_ name: String, _ bases: String) {
            text += "@\(name)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
        }
        for pair in 0..<20 {
            if pair == 10 { add("lone/1", "CCCCCCCCCCCCCCCC") }
            add("pair\(pair)/1", "GGGGGGGGGGGGGGGG")
            add("pair\(pair)/2", "TTTTTTTTTTTTTTTT")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unassigned-\(UUID().uuidString).fastq")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let paired = try await tallies(of: url, paired: true)
        XCTAssertEqual(paired.map(\.windows), [20, 20], "the single read belongs to neither mate")
        XCTAssertEqual(paired[0].composition?.first, [0, 0, 1, 0], "mate 1 starts with G")
        XCTAssertEqual(paired[1].composition?.first, [0, 0, 0, 1], "mate 2 starts with T")

        let single = try await tallies(of: url, paired: false)
        XCTAssertEqual(single.map(\.windows), [41], "a run of single reads tallies every record")
    }

    /// One pass of the default kit over an unassigned file.
    private func tallies(
        of url: URL, paired: Bool, compositionLimit: Int = DemultiplexChanceFloor.compositionReadLimit
    ) async throws -> [DemultiplexChanceFloor.StartTally] {
        try await DemultiplexChanceFloor.unassignedStartTallies(
            fastqURL: url, patterns: defaultKitPatterns, errorRate: errorRate, allowsIndels: true, paired: paired,
            compositionLimit: compositionLimit
        )
    }

    // MARK: - Review fixes (DEMUXNULL-BIO SF2, DEMUXNULL-SWIFT SF1 and SF2)

    /// A side with three errors holds hundreds of thousands of matching read starts a decoy, so a kit of 20-base barcodes
    /// at -e 0.15 keeps the floor of random bases and never builds that decoy bank (BIO SF2). At the base the call built
    /// 1,000 decoys of about 224,535 keys each and did not return in a test's time.
    func testAKitWithThreeErrorsASideKeepsTheFloorOfRandomBases() {
        continueAfterFailure = false
        let patterns = ["LONG": ["^ACGTACGTACGTACGTACGT"]]
        let window = DemultiplexChanceFloor.startWindowLength(patterns: patterns, errorRate: 0.15)
        XCTAssertEqual(window, 24, "20 bases, 3 errors and one more base")
        var generator = DemuxFloorSeededGenerator(seed: 7)
        var tally = DemultiplexChanceFloor.StartTally(patterns: patterns, errorRate: 0.15, allowsIndels: true)
        XCTAssertNil(tally.decoys, "the tally never builds the decoy bank of a side with three errors")
        for _ in 0..<2_000 { tally.add(DemuxFloorFixtures.randomBases(window, using: &generator)) }
        XCTAssertEqual(tally.windows, 2_000)
        XCTAssertEqual(DemultiplexChanceFloor.allowedErrors(length: 20, errorRate: 0.15), 3, "the kit must need three errors a side")
        XCTAssertEqual(DemultiplexChanceFloor.maximumDecoyErrors, 2, "a cap of 3 would build the 224,000-key decoy bank here")
        XCTAssertTrue(tally.isPackable)
        XCTAssertGreaterThanOrEqual(tally.windows, DemultiplexChanceFloor.minimumCompositionWindows)
        XCTAssertNil(DemultiplexChanceFloor.measuredNull(
            patterns: patterns, errorRate: 0.15, allowsIndels: true, unit: 1, tallies: [tally]
        ))
    }

    /// A kit with no decoy bank has nothing to count past the composition reads, so the pass stops at the limit as it did before
    /// DEMUX-FLOOR-DECOY-SCALE, and it closes what it opened (SWIFT SF1). A side with three errors builds no bank.
    func testAKitWithNoDecoyBankStopsReadingAtTheCompositionLimit() async throws {
        let patterns = ["LONG": ["^ACGTACGTACGTACGTACGT"]]
        var generator = DemuxFloorSeededGenerator(seed: 11)
        let url = try writeFASTQ((0..<1_500).map { _ in [DemuxFloorFixtures.randomBases(40, using: &generator)] })
        defer { try? FileManager.default.removeItem(at: url) }
        func pass() async throws -> [DemultiplexChanceFloor.StartTally] {
            try await DemultiplexChanceFloor.unassignedStartTallies(
                fastqURL: url, patterns: patterns, errorRate: 0.15, allowsIndels: true, paired: false, compositionLimit: 1_000
            )
        }
        let tallied = try await pass()
        XCTAssertEqual(tallied.map(\.reads), [1_000], "a kit with no decoy bank stops reading at the limit")
        XCTAssertEqual(tallied.map(\.windows), [1_000])
        XCTAssertNil(tallied.first?.decoys, "a side with three errors builds no decoy bank")
        let open = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<5 { _ = try await pass() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, open, "the early stop left files open")
    }

    /// The composition takes the first 200,000 records of a plain or a gzipped file, the decoys are counted on every record,
    /// and the pass closes what it opens (SWIFT SF2, DEMUX-FLOOR-DECOY-SCALE).
    func testTheCompositionStopsAtTheLimitAndTheDecoysCountEveryReadInPlainAndGzippedFiles() async throws {
        let limit = DemultiplexChanceFloor.compositionReadLimit
        var text = ""
        text.reserveCapacity((limit + 500) * 48)
        for index in 0..<(limit + 500) { text += "@r\(index)\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tally-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("unassigned.fastq")
        let gzipped = folder.appendingPathComponent("unassigned.fastq.gz")
        let data = Data(text.utf8)
        try data.write(to: plain)
        try GzipPin.gzip(["-c"], stdin: data).write(to: gzipped)

        for url in [plain, gzipped] {
            let tallied = try await tallies(of: url, paired: false)
            XCTAssertEqual(tallied.map(\.reads), [limit + 500], url.lastPathComponent)
            XCTAssertEqual(tallied.map(\.windows), [limit], url.lastPathComponent)
            XCTAssertEqual(tallied.map(\.countedWindows), [limit + 500], url.lastPathComponent)
        }
        let open = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for round in 0..<20 {
            _ = try await tallies(of: round.isMultiple(of: 2) ? gzipped : plain, paired: false)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, open, "the tally left files open")
    }

    /// A cancelled pass throws, so the floor never judges a tally of part of the file (DEMUX-FLOOR-DECOY-SCALE).
    func testACancelledPassThrowsInsteadOfReturningPartOfTheFile() async throws {
        var generator = DemuxFloorSeededGenerator(seed: 9)
        let url = try writeFASTQ((0..<5_000).map { _ in [DemuxFloorFixtures.randomBases(40, using: &generator)] })
        defer { try? FileManager.default.removeItem(at: url) }
        let patterns = defaultKitPatterns
        let rate = errorRate
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let pass = Task { () throws -> [DemultiplexChanceFloor.StartTally] in
            for await _ in gate {}
            return try await DemultiplexChanceFloor.unassignedStartTallies(
                fastqURL: url, patterns: patterns, errorRate: rate, allowsIndels: true, paired: false
            )
        }
        pass.cancel()
        do {
            _ = try await pass.value
            XCTFail("a cancelled pass returned a tally")
        } catch is CancellationError {}
    }

    // MARK: - A decoy that expects far less than one read (BIO-DEMUX-SPARSE-MARGIN)

    private let sparsePatterns = ["FLD0001": ["^GTATCGTCGT"]]

    /// 1,500 random reads tallied for a 10-base exact barcode. Each of its 1,000 decoys expects about 0.0014 reads.
    private func sparseTally(seed: UInt64) -> DemultiplexChanceFloor.StartTally {
        var generator = DemuxFloorSeededGenerator(seed: seed)
        var tally = DemultiplexChanceFloor.StartTally(patterns: sparsePatterns, errorRate: 0, allowsIndels: true)
        for _ in 0..<1_500 { tally.add(DemuxFloorFixtures.randomBases(40, using: &generator)) }
        return tally
    }

    /// The floor for the lone barcode with 5 reads among 1,505 searched, 1,500 of them unassigned.
    private func sparseOutcome(_ tally: DemultiplexChanceFloor.StartTally) -> DemultiplexChanceFloor.Outcome {
        DemultiplexChanceFloor.evaluate(
            patterns: sparsePatterns, counts: ["FLD0001": 5], readsSearched: 1_505, unassigned: 1_500, errorRate: 0,
            allowsIndels: true, pairedFragments: false, unassignedStarts: [tally]
        )
    }

    /// One chance read on one decoy must not set the margin. A decoy of a 10-base exact barcode expects 0.0014 reads in 1,500,
    /// so when one read lands on one of the 1,000 decoys (15 seeds in 20 at the base) its ratio is 566 to 1,083 and the
    /// margin of random reads jumped from 2 to that, which asked 10 or 11 reads of a barcode that 3 beat. Only a decoy whose
    /// reads chance at twice its share does not explain sets the margin (the lane's 614).
    func testOneChanceReadOnOneDecoyDoesNotSetTheMargin() {
        var marginTwo = 0
        var beating = 0
        var margins: [String] = []
        for seed in 2_000..<2_020 {
            let outcome = sparseOutcome(sparseTally(seed: UInt64(seed)))
            if outcome.margin == 2 { marginTwo += 1 }
            if outcome.barcodes.first(where: { $0.barcodeID == "FLD0001" })?.beatsTheFloor == true { beating += 1 }
            margins.append("\(seed): \(outcome.margin)")
        }
        print("DEMUXSPARSE margin 2 in \(marginTwo) of 20 seeds, 5 reads beat the floor in \(beating)")
        XCTAssertGreaterThanOrEqual(marginTwo, 18, "seeds with margin 2: \(marginTwo) of 20, margins \(margins)")
        XCTAssertGreaterThanOrEqual(beating, 18, "seeds where 5 reads beat the floor: \(beating) of 20")
    }

    /// A run past the read limit keeps the sparse rule (DEMUX-FLOOR-DECOY-SCALE). Seed 2,000 holds one chance read on one decoy,
    /// whose ratio of 566 set the margin under the rule a cut tally kept. Here the composition stops at read 1,000, a chance
    /// read on another decoy comes after it, every decoy is counted on all 1,501 reads, chance at twice its share explains
    /// each, and the margin stays 2, so 5 reads of the 10-base barcode beat the floor.
    func testARunPastTheReadLimitKeepsTheSparseRule() async throws {
        var generator = DemuxFloorSeededGenerator(seed: 2_000)
        var starts = (0..<1_500).map { _ in DemuxFloorFixtures.randomBases(40, using: &generator) }
        let index = try XCTUnwrap(sparseTally(seed: 2_000).decoys)
        let before = sparseTally(seed: 2_000).decoyCounts()
        let empty = try XCTUnwrap(before.firstIndex(of: 0))
        let decoy = String(index.decoys[empty].pattern.map { Character(["A", "C", "G", "T"][Int($0)]) })
        starts.append(decoy + DemuxFloorFixtures.randomBases(30, using: &generator))
        let url = try writeFASTQ(starts.map { [$0] })
        defer { try? FileManager.default.removeItem(at: url) }

        let tallied = try await DemultiplexChanceFloor.unassignedStartTallies(
            fastqURL: url, patterns: sparsePatterns, errorRate: 0, allowsIndels: true, paired: false, compositionLimit: 1_000
        )
        XCTAssertEqual(tallied.map(\.windows), [1_000], "the composition stops at the limit")
        XCTAssertEqual(tallied.map(\.countedWindows), [1_501], "the decoys count every read")
        XCTAssertEqual(tallied.first?.decoyCounts()[empty], 1, "the read past the limit is counted for its decoy")
        let outcome = DemultiplexChanceFloor.evaluate(
            patterns: sparsePatterns, counts: ["FLD0001": 5], readsSearched: 1_506, unassigned: 1_501, errorRate: 0,
            allowsIndels: true, pairedFragments: false, unassignedStarts: tallied
        )
        XCTAssertEqual(outcome.margin, 2, "a run past the read limit keeps the sparse rule")
        XCTAssertEqual(outcome.barcodes.first?.beatsTheFloor, true, "5 reads of a 10-base exact barcode beat the floor")
    }

    /// A FASTQ of `records`, each one or two reads, a pair named `/1` and `/2` by the mate rule.
    private func writeFASTQ(_ records: [[String]]) throws -> URL {
        var text = ""
        for (index, reads) in records.enumerated() {
            for (mate, bases) in reads.enumerated() {
                let name = reads.count == 2 ? "p\(index)/\(mate + 1)" : "s\(index)"
                text += "@\(name)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decoys-\(UUID().uuidString).fastq")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// For each decoy of the default kit, the reads among `reads` whose window matches it under the floor's dynamic program.
    /// A read shorter than the window or with an `N` in it makes no window.
    private func bruteForceDecoyCounts(_ reads: [String], index: DemultiplexChanceFloor.DecoyIndex) -> [Int] {
        let window = DemultiplexChanceFloor.startWindowLength(patterns: defaultKitPatterns, errorRate: errorRate)
        let codes = reads.map { DemultiplexChanceFloor.baseCodes($0) }
            .filter { $0.count >= window && !$0.prefix(window).contains(where: { $0 > 3 }) }
        return index.decoys.map { decoy in
            codes.filter {
                DemultiplexChanceFloor.anchoredMatch(read: $0, pattern: decoy.pattern, errors: decoy.errors, allowsIndels: true)
            }.count
        }
    }

    /// The decoy counts of one pass equal a brute-force count over every unassigned read with the floor's dynamic program, in a
    /// plain, a gzipped and a paired file, past the composition limit (DEMUX-FLOOR-DECOY-SCALE).
    func testTheDecoyCountsOfOnePassEqualABruteForceCountOverEveryRead() async throws {
        var generator = DemuxFloorSeededGenerator(seed: 31)
        var pairs = (0..<400).map { _ in (0..<2).map { _ in DemuxFloorFixtures.randomBases(20, using: &generator) } }
        pairs[5][0] = "ACGTN" + DemuxFloorFixtures.randomBases(15, using: &generator)
        pairs[7][1] = "ACGTACG"
        let lone = DemuxFloorFixtures.randomBases(20, using: &generator)
        let index = try XCTUnwrap(DemultiplexChanceFloor.StartTally(
            patterns: defaultKitPatterns, errorRate: errorRate, allowsIndels: true
        ).decoys)
        let mate1 = bruteForceDecoyCounts(pairs.map { $0[0] }, index: index)
        let mate2 = bruteForceDecoyCounts(pairs.map { $0[1] }, index: index)
        let every = zip(zip(mate1, mate2), bruteForceDecoyCounts([lone], index: index)).map { $0.0 + $0.1 + $1 }
        XCTAssertGreaterThan(every.reduce(0, +), 300, "the random reads hit many decoys")

        let pairedURL = try writeFASTQ(Array(pairs.prefix(200)) + [[lone]] + Array(pairs.suffix(200)))
        defer { try? FileManager.default.removeItem(at: pairedURL) }
        let paired = try await tallies(of: pairedURL, paired: true, compositionLimit: 300)
        XCTAssertEqual(paired.map { $0.decoyCounts() }, [mate1, mate2], "each mate by the mate rule, the lone read in neither")
        XCTAssertEqual(paired.map(\.windows), [149, 149], "the composition stops at record 300, less the N and the short read")

        let gzipped = pairedURL.appendingPathExtension("gz")
        try GzipPin.gzip(["-c"], stdin: Data(contentsOf: pairedURL)).write(to: gzipped)
        defer { try? FileManager.default.removeItem(at: gzipped) }
        for url in [pairedURL, gzipped] {
            let single = try await tallies(of: url, paired: false, compositionLimit: 300)
            XCTAssertEqual(single.first?.decoyCounts(), every, url.lastPathComponent)
            XCTAssertEqual(single.map(\.countedWindows), [799], "801 records, one with an N and one too short")
        }
    }

    // MARK: - Every decoy over every unassigned read (DEMUX-FLOOR-DECOY-SCALE)

    /// DEMUX-FLOOR-DECOY-SCALE (BIO-DEMUX-SPARSE-MARGIN item 9). A run left with more than 200,000 reads that carry no barcode
    /// counted its decoys on the first 200,000 and its barcodes on all of them, so there every decoy set the margin, and one
    /// chance read on one decoy of a 12-base exact kit raised it far past 2 (167 here). Counted on every read, each decoy expects about
    /// 0.015 reads in 250,000 random reads, chance at twice its share explains its reads, and the margin is 2. A 12-base
    /// barcode with 3 chance reads then stays at or below the floor, and a real sample still beats it. The run goes through
    /// the floor the pipeline calls.
    func testARunPastTheReadLimitCountsEveryDecoyOnEveryRead() async throws {
        let reads = DemultiplexChanceFloor.compositionReadLimit + 50_000
        var generator = DemuxFloorSeededGenerator(seed: 4_242)
        let quality = String(repeating: "I", count: 24)
        var text = ""
        text.reserveCapacity(reads * 64)
        for index in 0..<reads { text += "@u\(index)\n\(DemuxFloorFixtures.randomBases(24, using: &generator))\n+\n\(quality)\n" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("decoy-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unassignedURL = folder.appendingPathComponent("unassigned.fastq")
        try Data(text.utf8).write(to: unassignedURL)
        let realBarcode = "GTATCGTCGTAC"
        let longBarcode = "CAACTGCAACAT"
        let adapterFASTA = folder.appendingPathComponent("barcodes.fasta")
        try ">REAL\n^\(realBarcode)\n>LONG\n^\(longBarcode)\n".write(to: adapterFASTA, atomically: true, encoding: .utf8)
        let kit = BarcodeKitDefinition(
            id: "custom-decoy-scale", displayName: "Custom 12-base kit", vendor: "custom", isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [BarcodeEntry(id: "REAL", i7Sequence: realBarcode), BarcodeEntry(id: "LONG", i7Sequence: longBarcode)]
        )
        let config = DemultiplexConfig(
            inputURL: unassignedURL, barcodeKit: kit, outputDirectory: folder, barcodeLocation: .fivePrime, errorRate: 0,
            adapterContext: BareAdapterContext()
        )
        let floor = try await DemultiplexingPipeline().requireBarcodesAboveChance(
            config: config, adapterFASTA: adapterFASTA, counts: ["REAL": 500, "LONG": 3], readsSearched: reads + 503,
            unassigned: reads, paired: false, unassignedReadsURL: unassignedURL
        )
        let outcome = try XCTUnwrap(floor)
        let long = outcome.barcodes.first { $0.barcodeID == "LONG" }
        print("DECOYSCALE margin \(outcome.margin), composition \(outcome.compositionReads), LONG ceiling \(long?.chanceCeiling ?? -1)")
        XCTAssertEqual(outcome.null, .startComposition)
        XCTAssertEqual(outcome.compositionReads, DemultiplexChanceFloor.compositionReadLimit, "the composition comes from the first reads")
        XCTAssertEqual(outcome.margin, 2, "a run past the read limit keeps the sparse rule, since every decoy is counted on every read")
        XCTAssertEqual(long?.beatsTheFloor, false, "3 chance reads on a 12-base exact barcode stay at or below the floor")
        XCTAssertEqual(outcome.barcodes.first { $0.barcodeID == "REAL" }?.beatsTheFloor, true, "a real sample still beats it")
    }
}
