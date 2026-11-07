// DemultiplexHeaderIndexScoutTests.swift - Detect Barcodes counts the index in the read names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DETECTHDR (L9, L5). Detect Barcodes built its search from the kit's context, whose 5' side is empty
// for TruSeq, Nextera and MGI, so it refused every Illumina, Element, Ultima and MGI kit before any search
// (ILLUMINA-KIT-DETECT-NO-SEARCH), and it accepted a barcode at an absolute 10 hits (DETECT-ABSOLUTE-ACCEPT). For
// Illumina and Element kits it now counts the index in the read names with the run's own parser and caller, and it
// accepts a barcode only above the bound the run's route owner uses, so Detect and the run name the same barcodes on
// the same reads. These tests run no tool: the count reads the names only.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexHeaderIndexScoutTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-header-scout")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    private static let d701 = "ATTACTCG"
    private static let d702 = "TCCGGAGA"

    /// `index` changed at one base, as L6's mixed fixture changes it (`DemuxFloorFixtures.mixedHeaderNames`), so the
    /// name lies one mismatch from D701 and far from every other barcode of the default kit.
    private static func oneMismatch(from index: String, _ k: Int) -> String {
        var bases = Array(index)
        let position = k % bases.count
        let alphabet = DemuxFloorFixtures.bases
        bases[position] = alphabet[(alphabet.firstIndex(of: bases[position])! + 1 + k / bases.count) % 4]
        return String(bases)
    }

    /// One read a comment, named `r<n> <comment>`, with random bases from a fixed seed, in the project.
    private func write(_ comments: [String], to file: String) throws -> URL {
        let url = project.appendingPathComponent(file)
        try DemuxFloorFixtures.write(names: comments.enumerated().map { "r\($0.offset) \($0.element)" }, seed: 7, to: url)
        return url
    }

    private func scout(_ input: URL, kit: BarcodeKitDefinition = BarcodeKitRegistry.truseqSingleA) async throws -> BarcodeScoutResult {
        try await DemultiplexingPipeline().scout(inputURL: input, kit: kit, errorRate: 0.15, progress: { _, _ in })
    }

    private func accepted(_ result: BarcodeScoutResult) -> [String: Int] {
        Dictionary(result.acceptedDetections.map { ($0.barcodeID, $0.hitCount) }, uniquingKeysWith: +)
    }

    /// BIO's first test (`S2-R1-BIO.md:60`): 900 names carry D701, 15 of them at one mismatch and 5 with a no-call at
    /// the first index cycle, as the first tiles of a MiSeq run give, and 100 carry D702. Detect names D701 and D702 with
    /// their header tallies and no other barcode. The base built an empty search and threw `emptyAdapterSequences`.
    func testDetectCountsHeaderIndexesForTheDefaultKit() async throws {
        var comments = Array(repeating: "1:N:0:\(Self.d701)", count: 880) + Array(repeating: "1:N:0:\(Self.d702)", count: 100)
        comments += (0..<15).map { "1:N:0:" + Self.oneMismatch(from: Self.d701, $0) }
        comments += Array(repeating: "1:N:0:N" + Self.d701.dropFirst(), count: 5)
        let result = try await scout(try write(comments, to: "default.fastq"))

        XCTAssertEqual(result.readsScanned, 1_000)
        XCTAssertEqual(accepted(result), ["D701": 900, "D702": 100])
        XCTAssertEqual(result.detections.map(\.barcodeID).sorted(), ["D701", "D702"], "no other barcode is named")
        XCTAssertEqual(result.unassignedCount, 0)
    }

    /// BIO's second test (`S2-R1-BIO.md:61`): names as SRA writes them by default carry no index, so Detect refuses in
    /// words that say the read names hold no index, not that the kit gave no sequence to search for.
    func testDetectRefusesWhenHeadersCarryNoIndex() async throws {
        let input = project.appendingPathComponent("sra.fastq")
        try DemuxFloorFixtures.write(names: (1...1_000).map { "SRR2584863.\($0) \($0) length=150" }, seed: 7, to: input)
        do {
            let result = try await scout(input)
            XCTFail("Detect counted \(result.detections.count) barcodes in names that carry no index")
        } catch {
            XCTAssertTrue(String(describing: error).hasPrefix("readNamesCarryNoIndex("), "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("found no index in them"), error.localizedDescription)
        }
    }

    /// BIO's third test (`S2-R1-BIO.md:62`): a dual-index kit is counted whether the names carry i5 as the kit lists it
    /// or reverse complemented, as instruments differ in the strand they read i5 from.
    func testDetectMatchesI5InEitherOrientation() async throws {
        let pairs = [("P1", Self.d701, "TATAGCCT"), ("P2", Self.d702, "ATAGAGGC"), ("P3", "CGCTCATT", "CCTATCCT")]
        let kit = BarcodeKitDefinition(
            id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
            barcodes: pairs.map { BarcodeEntry(id: $0.0, i7Sequence: $0.1, i5Sequence: $0.2) }
        )
        for reversed in [false, true] {
            let comments = zip(pairs, [600, 300, 100]).flatMap { pair, count in
                let i5 = reversed ? PlatformAdapters.reverseComplement(pair.2) : pair.2
                return Array(repeating: "1:N:0:\(pair.1)+\(i5)", count: count)
            }
            let result = try await scout(try write(comments, to: "dual-\(reversed).fastq"), kit: kit)
            XCTAssertEqual(accepted(result), ["P1": 600, "P2": 300, "P3": 100], reversed ? "i5 reverse complemented" : "i5 as listed")
        }
    }

    /// QA's agreement test (L9, `S33-R2-QA.md:52`): on L6's mixed fixture, no larger than Detect's subset, Detect accepts
    /// D701 and D702 with the counts the run writes, and no other barcode.
    func testDetectAndRunAgreeOnHeaderIndexedReads() async throws {
        let input = project.appendingPathComponent("mixed.fastq")
        try DemuxFloorFixtures.write(names: DemuxFloorFixtures.mixedHeaderNames(seed: 11), seed: 11, to: input)
        let detected = try await scout(input)
        let output = project.appendingPathComponent("out", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: input, barcodeKit: BarcodeKitRegistry.truseqSingleA, outputDirectory: output, errorRate: 0.15
        )
        let run = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        let ran = Dictionary(
            run.manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) }, uniquingKeysWith: +
        )

        XCTAssertEqual(accepted(detected), ["D701": 1_020, "D702": 100])
        XCTAssertEqual(accepted(detected), ran, "Detect and the run name the same barcodes with the same counts")
        XCTAssertEqual(detected.unassignedCount, run.manifest.unassigned.readCount)
    }

    /// BIO's dual-index agreement pin (`DETECTHDR-BIO.md` should-fix 2): the same agreement for a dual-index kit whose names
    /// carry i5 reverse complemented. Detect tallies with the caller over the whole kit and the run reads the kit the same
    /// way, so the two could part. 600, 300 and 100 names carry P1, P2 and P3, 5 more carry P1 with one mismatch in i5, 10
    /// pair P1's i7 with P2's i5 (index hopping) and 10 hold no call. A pin, green at the head.
    func testDetectAndRunAgreeOnDualIndexReadsWithI5ReverseComplemented() async throws {
        let pairs = [("P1", Self.d701, "TATAGCCT"), ("P2", Self.d702, "ATAGAGGC"), ("P3", "CGCTCATT", "CCTATCCT")]
        let kit = BarcodeKitDefinition(
            id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
            barcodes: pairs.map { BarcodeEntry(id: $0.0, i7Sequence: $0.1, i5Sequence: $0.2) }
        )
        var comments = zip(pairs, [600, 300, 100]).flatMap { pair, count in
            Array(repeating: "1:N:0:\(pair.1)+\(PlatformAdapters.reverseComplement(pair.2))", count: count)
        }
        comments += (0..<5).map { "1:N:0:\(pairs[0].1)+" + Self.oneMismatch(from: PlatformAdapters.reverseComplement(pairs[0].2), $0) }
        comments += Array(repeating: "1:N:0:\(pairs[0].1)+\(PlatformAdapters.reverseComplement(pairs[1].2))", count: 10)
        comments += Array(repeating: "1:N:0:NNNNNNNN+NNNNNNNN", count: 10)
        let input = try write(comments, to: "dual-agree.fastq")
        let detected = try await scout(input, kit: kit)
        let output = project.appendingPathComponent("out-dual", isDirectory: true)
        let config = DemultiplexConfig(inputURL: input, barcodeKit: kit, outputDirectory: output, errorRate: 0.15)
        let run = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        let ran = Dictionary(
            run.manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) }, uniquingKeysWith: +
        )

        XCTAssertEqual(Set(ran.keys), ["P1", "P2", "P3"], "the run names the three barcodes, so the pin is not empty on both sides")
        XCTAssertEqual(accepted(detected), ran, "Detect and the run name the same dual-index barcodes with the same counts")
        XCTAssertEqual(detected.unassignedCount, run.manifest.unassigned.readCount)
    }

    /// BIO's one-sample line (L9, `S33-R2-BIO.md:65`): when 99% or more of the names carry one index, the file reads as
    /// one sample, so Detect accepts no barcode as a plex and keeps the tally. At 98% the file is a plex of two.
    func testAFileWhoseNamesAlmostAllCarryOneIndexReadsAsOneSample() async throws {
        let one = Array(repeating: "1:N:0:\(Self.d701)", count: 990) + Array(repeating: "1:N:0:NNNNNNNN", count: 10)
        let single = try await scout(try write(one, to: "one.fastq"))
        XCTAssertTrue(single.acceptedDetections.isEmpty, "a one-sample file is not a plex: \(accepted(single))")
        XCTAssertEqual(single.detections.first { $0.barcodeID == "D701" }?.hitCount, 990)

        let two = Array(repeating: "1:N:0:\(Self.d701)", count: 980) + Array(repeating: "1:N:0:\(Self.d702)", count: 20)
        let plex = try await scout(try write(two, to: "two.fastq"))
        XCTAssertEqual(accepted(plex), ["D701": 980, "D702": 20])
    }

    /// DETECT-ABSOLUTE-ACCEPT on the read names: a barcode is accepted only above the chance bound the run's route owner
    /// uses (L5), never at an absolute 10. In 10,000 names, the 12 that carry D703 lie under that bound of 18.
    func testDetectAcceptsAReadNameIndexOnlyAboveTheChanceBound() async throws {
        let d703 = BarcodeKitRegistry.truseqSingleA.barcodes[2].i7Sequence
        let comments = Array(repeating: "1:N:0:\(Self.d701)", count: 4_994)
            + Array(repeating: "1:N:0:\(Self.d702)", count: 4_994) + Array(repeating: "1:N:0:\(d703)", count: 12)
        let result = try await scout(try write(comments, to: "bound.fastq"))
        let kitSize = Double(BarcodeKitRegistry.truseqSingleA.barcodes.count)
        let ceiling = DemultiplexChanceFloor.chanceCeiling(trials: 10_000, probability: 25.0 / 65_536, tail: 1e-6 / kitSize)

        XCTAssertGreaterThan(ceiling, 12, "the bound lies above the 12 names")
        XCTAssertEqual(accepted(result), ["D701": 4_994, "D702": 4_994])
        XCTAssertEqual(result.detections.first { $0.barcodeID == "D703" }?.hitCount, 12, "the 12 names are counted and shown")
    }

    /// BIO should-fix 1 of the DETECTHDR review: Apply must not put the absolute thresholds back on a count from the read
    /// names. Its accept line is the chance bound of L5, and `applyThresholds` accepted at `hitCount >= 10` whatever the
    /// source (DETECT-ABSOLUTE-ACCEPT again, by a person's own click). A count from the read names keeps the dispositions
    /// Detect gave it: 12 names of D703 stay under the bound of 18, and the one-sample barcode stays undecided.
    func testApplyThresholdsLeavesAReadNameCountAtItsChanceBound() async throws {
        let d703 = BarcodeKitRegistry.truseqSingleA.barcodes[2].i7Sequence
        let comments = Array(repeating: "1:N:0:\(Self.d701)", count: 4_994)
            + Array(repeating: "1:N:0:\(Self.d702)", count: 4_994) + Array(repeating: "1:N:0:\(d703)", count: 12)
        var result = try await scout(try write(comments, to: "apply-bound.fastq"))
        XCTAssertEqual(accepted(result), ["D701": 4_994, "D702": 4_994])

        result.applyThresholds(acceptMinHits: 10, rejectMaxHits: 3)

        XCTAssertEqual(accepted(result), ["D701": 4_994, "D702": 4_994], "Apply keeps the chance bound's accepts")
        XCTAssertEqual(result.detections.first { $0.barcodeID == "D703" }?.disposition, .rejected, "12 names stay under the bound")
    }

    /// The same press on a file that holds one sample (990 of 1,000 names carry D701): the scout leaves that barcode
    /// undecided and Apply keeps it so, since a plex of one barcode is no plan (BIO should-fix 1).
    func testApplyThresholdsLeavesTheOneSampleBarcodeUndecided() async throws {
        let one = Array(repeating: "1:N:0:\(Self.d701)", count: 990) + Array(repeating: "1:N:0:NNNNNNNN", count: 10)
        var single = try await scout(try write(one, to: "apply-one.fastq"))
        let states = { (result: BarcodeScoutResult) in result.detections.map { "\($0.barcodeID) \($0.hitCount) \($0.disposition)" } }
        XCTAssertEqual(states(single), ["D701 990 undecided"], "the scout leaves the one-sample barcode undecided")
        single.applyThresholds(acceptMinHits: 10, rejectMaxHits: 3)
        XCTAssertEqual(states(single), ["D701 990 undecided"], "Apply does not make the one-sample barcode a plex of one")
        XCTAssertTrue(single.acceptedDetections.isEmpty, "Apply does not make the one-sample barcode a plex: \(accepted(single))")
    }

    /// BIO's line for the header share (`S33-R2-BIO.md:65`): each sample of an even 384-plex, near 0.26% of the reads,
    /// is found. 384 barcodes of 8 bases at least three apart, 26 names each.
    func testDetectFindsEverySampleOfAnEven384PlexByItsNames() async throws {
        var generator = DemuxFloorSeededGenerator(seed: 384)
        var sequences: [String] = []
        while sequences.count < 384 {
            let candidate = DemuxFloorFixtures.randomBases(8, using: &generator)
            if sequences.allSatisfy({ DemuxFloorFixtures.mismatches($0, candidate) >= 3 }) { sequences.append(candidate) }
        }
        let kit = BarcodeKitDefinition(
            id: "plex384", displayName: "Plex 384", platform: .illumina,
            barcodes: sequences.enumerated().map { BarcodeEntry(id: String(format: "S%03d", $0.offset + 1), i7Sequence: $0.element) }
        )
        let comments = sequences.flatMap { Array(repeating: "1:N:0:\($0)", count: 26) }
        let result = try await scout(try write(comments, to: "plex.fastq"), kit: kit)

        XCTAssertEqual(result.acceptedCount, 384)
        XCTAssertEqual(Set(result.acceptedDetections.map(\.hitCount)), [26])
    }

    /// A custom definition's run reads the read names first (the route owner), so when the names carry two or more of
    /// its barcodes Detect counts the names too, and a definition typed from a sample sheet is counted as it runs.
    func testDetectOfACustomDefinitionWhoseNamesCarryItsIndexesCountsTheNames() async throws {
        let kit = try BarcodeKitRegistry.loadCustomKit(text: "S1,\(Self.d701)\nS2,\(Self.d702)\n", name: "Sheet")
        let comments = Array(repeating: "1:N:0:\(Self.d701)", count: 700) + Array(repeating: "1:N:0:\(Self.d702)", count: 300)
        let result = try await scout(try write(comments, to: "sheet.fastq"), kit: kit)

        XCTAssertEqual(accepted(result), ["S1": 700, "S2": 300])
    }
}

/// A real-tool suite. Its name puts it in the conformance tier, and it skips when managed cutadapt or seqkit is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class DemultiplexHeaderIndexScoutConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-header-scout-tools")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    /// A GBS key as a custom definition, on reads whose names all carry one library index: the names hold none of its
    /// barcodes, so Detect still searches the read bases, as the run's route owner does (green at the base and after).
    func testCustomDefinitionOnNamesWithOneLibraryIndexStillSearchesTheBases() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
            return
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let kit = try BarcodeKitRegistry.loadCustomKit(text: "G1,ACGGTCAT\nG2,GTTACCGA\n", name: "GBS key")
        let input = project.appendingPathComponent("gbs.fastq")
        try DemuxFloorFixtures.write(
            names: (0..<1_000).map { "r\($0) 1:N:0:AGTACTCG" },
            leads: (0..<1_000).map { $0 < 500 ? "ACGGTCAT" : "GTTACCGA" }, seed: 5, to: input
        )
        let result = try await DemultiplexingPipeline().scout(inputURL: input, kit: kit, errorRate: 0.15, progress: { _, _ in })

        // The search of the bases finds both barcodes, as at the base (52 and 47 of the 500 reads each, a count this
        // lane does not change), and the names' one library index is no barcode of the key.
        XCTAssertEqual(Set(result.acceptedDetections.map(\.barcodeID)), ["G1", "G2"])
        XCTAssertTrue(result.detections.allSatisfy { $0.hitCount < 500 }, "\(result.detections.map(\.hitCount))")
    }
}
