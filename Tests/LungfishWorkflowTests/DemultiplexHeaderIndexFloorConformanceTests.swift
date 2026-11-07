// DemultiplexHeaderIndexFloorConformanceTests.swift - A run reads the index in the read names before it searches bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L1, L5, L6). A run of TruSeq Single Index Set A on reads whose index sits only in their
// names searched the read bases for the bare index and gave about 0.93% of the reads a barcode by chance
// (DEMUX-HEADER-INDEX-NOT-READ, S1). Reads whose names carry two or more of the kit's indexes are split by those
// names (DemultiplexHeaderIndexSplitTests), and a search of the bases in which no barcode beats BIO's chance floor
// publishes no barcode output.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// A seeded generator, so each fixture holds the same bases on every run.
struct DemuxFloorSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The reads of these tests, written as FASTQ with quality `I` on every base.
enum DemuxFloorFixtures {
    static let bases: [Character] = ["A", "C", "G", "T"]

    static func randomBases(_ count: Int, using generator: inout DemuxFloorSeededGenerator) -> String {
        String((0..<count).map { _ in bases[Int(generator.next() % 4)] })
    }

    static func mismatches(_ a: String, _ b: String) -> Int {
        guard a.count == b.count else { return Int.max }
        return zip(a, b).filter { $0 != $1 }.count
    }

    /// One read a name, `@<name>`, whose bases are `lead` (if any) and then random bases up to `length`.
    static func write(names: [String], leads: [String] = [], seed: UInt64, length: Int = 150, to url: URL) throws {
        var generator = DemuxFloorSeededGenerator(seed: seed)
        var text = ""
        text.reserveCapacity(names.count * (2 * length + 40))
        for (index, name) in names.enumerated() {
            let lead = index < leads.count ? leads[index] : ""
            let sequence = lead + randomBases(max(0, length - lead.count), using: &generator)
            text += "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// L6's mixed fixture: 1,000 names carry D701, 100 D702, 20 D701 at one mismatch and 10 `NNNNNNNN`, shuffled.
    static func mixedHeaderNames(seed: UInt64) -> [String] {
        var comments = Array(repeating: "1:N:0:ATTACTCG", count: 1_000) + Array(repeating: "1:N:0:TCCGGAGA", count: 100)
        for k in 0..<20 {
            var index = Array("ATTACTCG")
            let position = k % 8
            index[position] = bases[(bases.firstIndex(of: index[position])! + 1 + k / 8) % 4]
            comments.append("1:N:0:" + String(index))
        }
        comments += Array(repeating: "1:N:0:NNNNNNNN", count: 10)
        var generator = DemuxFloorSeededGenerator(seed: seed)
        comments.shuffle(using: &generator)
        return comments.enumerated().map { "r\($0.offset) \($0.element)" }
    }
}

/// A real-tool suite. Its name puts it in the conformance tier, and it skips when managed cutadapt or seqkit is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class DemultiplexHeaderIndexFloorConformanceTests: XCTestCase {
    private var root: URL!
    private static let kit = BarcodeKitRegistry.truseqSingleA
    private static let chanceWords = "matched more reads than chance alone gives"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-header-floor")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTools() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
        }
    }

    private func project(_ name: String) throws -> URL {
        let project = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func visibleItems(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A run at the dialog's defaults. With no engine named, the run asks the route owner.
    private func run(_ input: URL, output: URL, explicitCutadapt: Bool = false) async throws -> DemultiplexResult {
        let config = explicitCutadapt
            ? DemultiplexConfig(inputURL: input, barcodeKit: Self.kit, outputDirectory: output, errorRate: 0.15, threads: 1,
                                engine: .cutadapt)
            : DemultiplexConfig(inputURL: input, barcodeKit: Self.kit, outputDirectory: output, errorRate: 0.15, threads: 1)
        return try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
    }

    /// Runs `input` and asserts a refusal that holds `words` and leaves no output. Returns the reads given a barcode
    /// when the run did not refuse, which is the base's count of chance matches.
    @discardableResult
    private func assertRefuses(
        _ input: URL, output: URL, words: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Int {
        var assigned = 0
        do {
            let result = try await run(input, output: output)
            assigned = result.manifest.assignedReadCount
            XCTFail("The run published \(result.outputBundleURLs.count) barcode outputs with \(assigned) reads", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(words), error.localizedDescription, file: file, line: line)
        }
        XCTAssertEqual(visibleItems(in: output), [], "no output is published", file: file, line: line)
        // The staging folder and the provenance sidecar start with a dot, so `visibleItems` cannot see them.
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
            .filter { $0.hasPrefix(".lungfish-demux-incomplete-") || $0.hasSuffix("lungfish-provenance.json") }
        XCTAssertEqual(leftovers, [], "a refused run leaves no staging folder and no record", file: file, line: line)
        return assigned
    }

    private func readIDs(_ result: DemultiplexResult, output: URL) async throws -> [String: Set<String>] {
        var ids: [String: Set<String>] = [:]
        for barcode in result.manifest.barcodes {
            let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
            for try await record in FASTQReader(validateSequence: false).records(from: payload) {
                ids[barcode.barcodeID, default: []].insert(record.identifier)
            }
        }
        return ids
    }

    /// L6's mixed fixture holds what its split test needs: each of the 20 names one mismatch from D701 lies two or
    /// more mismatches from every other barcode, so a split at one mismatch gives it to D701 alone.
    func testMixedFixtureNamesOneMismatchFromD701LieFarFromEveryOtherBarcode() {
        let names = DemuxFloorFixtures.mixedHeaderNames(seed: 11)
        for name in names where name.hasSuffix(":N:0:NNNNNNNN") == false && !name.hasSuffix("ATTACTCG") && !name.hasSuffix("TCCGGAGA") {
            let index = String(name.split(separator: ":").last!)
            for barcode in Self.kit.barcodes where barcode.id != "D701" {
                XCTAssertGreaterThanOrEqual(DemuxFloorFixtures.mismatches(index, barcode.i7Sequence), 2, "\(index) near \(barcode.id)")
            }
        }
    }

    func testTruSeqRunOnReadsWithAnEmptyIndexInTheirNamesAssignsNoRead() async throws {
        try await requireTools()
        for barcode in Self.kit.barcodes {
            XCTAssertGreaterThan(DemuxFloorFixtures.mismatches("GGGGGGGG", barcode.i7Sequence), 2, barcode.id)
        }
        let project = try project("Empty")
        let input = project.appendingPathComponent("empty-index.fastq")
        try DemuxFloorFixtures.write(names: (0..<10_000).map { "r\($0) 1:N:0:GGGGGGGG" }, seed: 7, to: input)
        let assigned = try await assertRefuses(input, output: project.appendingPathComponent("out"), words: Self.chanceWords)
        print("DEMUXRUN empty-index fixture seed 7: \(assigned) of 10000 reads given a barcode")
    }

    /// BIO-DEMUX-FLOOR item 9: one sample's names (D701 in every name, random bases) take the bases search, and the
    /// floor ends the run in its own words, which name a file already split into one file per sample.
    func testOneSampleNamesTakeTheBasesSearchAndTheFloorSpeaks() async throws {
        try await requireTools()
        let project = try project("OneSample")
        let input = project.appendingPathComponent("one-sample.fastq")
        try DemuxFloorFixtures.write(names: (0..<10_000).map { "r\($0) 1:N:0:ATTACTCG" }, seed: 9, to: input)
        let assigned = try await assertRefuses(input, output: project.appendingPathComponent("out"), words: Self.chanceWords)
        print("DEMUXRUN one-sample names seed 9: \(assigned) of 10000 reads given a barcode")
    }

    func testTruSeqRunOnReadsWithNoIndexAnywhereAssignsNoRead() async throws {
        try await requireTools()
        var countsBySeed: [UInt64: Int] = [:]
        for seed in UInt64(1)...20 {
            let project = try project("NoIndex\(seed)")
            let input = project.appendingPathComponent("no-index.fastq")
            try DemuxFloorFixtures.write(names: (1...10_000).map { "SRR000001.\($0) \($0) length=150" }, seed: seed, to: input)
            countsBySeed[seed] = try await assertRefuses(input, output: project.appendingPathComponent("out"), words: Self.chanceWords)
        }
        print("DEMUXRUN no-index fixture, reads given a barcode by seed: \(countsBySeed.sorted { $0.key < $1.key })")
    }

    /// QA's measure (L5): the no-index fixture over many seeds publishes no bundle in any. It runs only when
    /// LUNGFISH_DEMUX_FLOOR_MEASURE_SEEDS names the seed count, as `LUNGFISH_DEMUX_FLOOR_MEASURE_SEEDS=200`.
    func testChanceFloorMeasureOverSeedsPublishesNoBundle() async throws {
        guard let seeds = ProcessInfo.processInfo.environment["LUNGFISH_DEMUX_FLOOR_MEASURE_SEEDS"].flatMap(Int.init) else {
            throw XCTSkip("set LUNGFISH_DEMUX_FLOOR_MEASURE_SEEDS to run the measure")
        }
        try await requireTools()
        var published = 0
        var refusedByFloor = 0
        for seed in 1...seeds {
            let project = try project("Measure\(seed)")
            let input = project.appendingPathComponent("no-index.fastq")
            try DemuxFloorFixtures.write(names: (1...10_000).map { "SRR000001.\($0) \($0) length=150" }, seed: UInt64(1_000 + seed), to: input)
            let output = project.appendingPathComponent("out")
            // Only the floor's own refusal counts: a tool failure or any other error is no pass (DEMUXFLOOR-QA SF2).
            do {
                _ = try await run(input, output: output)
                published += 1
            } catch let error as DemultiplexError {
                if case .noBarcodeAboveChance = error { refusedByFloor += 1 }
            } catch {}
            if !visibleItems(in: output).isEmpty { published += 1 }
            try? FileManager.default.removeItem(at: project)
        }
        print("DEMUXRUN measure: \(published) of \(seeds) seeds published a bundle, \(refusedByFloor) refused by the floor")
        XCTAssertEqual(published, 0)
        XCTAssertEqual(refusedByFloor, seeds)
    }

    func testInlineKitOnReadsWhoseNamesCarryOneLibraryIndexKeepsTheInlineSplit() async throws {
        try await requireTools()
        let library = "GTCAGTAC"
        for barcode in Self.kit.barcodes {
            XCTAssertGreaterThanOrEqual(DemuxFloorFixtures.mismatches(library, barcode.i7Sequence), 2, barcode.id)
        }
        let names = (0..<200).map { "r\($0) 1:N:0:\(library)" }
        let leads = Array(repeating: "ATTACTCG", count: 80) + Array(repeating: "TCCGGAGA", count: 80)
        let project = try project("Library")
        let input = project.appendingPathComponent("library-index.fastq")
        try DemuxFloorFixtures.write(names: names, leads: leads, seed: 5, to: input)

        let routed = project.appendingPathComponent("routed")
        let routedResult = try await run(input, output: routed)
        let explicit = project.appendingPathComponent("explicit")
        let explicitResult = try await run(input, output: explicit, explicitCutadapt: true)

        let routedIDs = try await readIDs(routedResult, output: routed)
        let explicitIDs = try await readIDs(explicitResult, output: explicit)
        XCTAssertEqual(routedIDs, explicitIDs, "same reads in each output")
        XCTAssertTrue(Set((0..<80).map { "r\($0)" }).isSubset(of: routedIDs["D701"] ?? []))
        XCTAssertTrue(Set((80..<160).map { "r\($0)" }).isSubset(of: routedIDs["D702"] ?? []))
        XCTAssertEqual(routedResult.manifest.unassigned.readCount, explicitResult.manifest.unassigned.readCount)
        // The published result keeps the floor, so the CLI's summary and record can name barcodes within chance.
        XCTAssertNotNil(routedResult.chanceFloor, "the staging area dropped the chance floor")
    }

    /// When a read's name and its leading bases carry the same index, the split by the names and cutadapt's search of
    /// the bases give it the same barcode, so the route changes where the barcode is read and not the result.
    func testHeaderAndInlineRoutesGiveEachReadTheSameBarcodeWhenItsNameAndBasesAgree() async throws {
        try await requireTools()
        let barcodes = ["D701", "D702", "D703"].compactMap { id in Self.kit.barcodes.first { $0.id == id } }
        XCTAssertEqual(barcodes.count, 3)
        let indexes = barcodes.flatMap { Array(repeating: $0.i7Sequence, count: 100) }
        let project = try project("Parity")
        let input = project.appendingPathComponent("agree.fastq")
        try DemuxFloorFixtures.write(
            names: indexes.enumerated().map { "r\($0.offset) 1:N:0:\($0.element)" }, leads: indexes, seed: 9, to: input
        )

        let routed = project.appendingPathComponent("routed")
        let routedResult = try await run(input, output: routed)
        XCTAssertEqual(routedResult.manifest.parameters.tool, "header-index-demux")
        let explicit = project.appendingPathComponent("explicit")
        let explicitResult = try await run(input, output: explicit, explicitCutadapt: true)
        XCTAssertNotEqual(explicitResult.manifest.parameters.tool, "header-index-demux")

        let routedIDs = try await readIDs(routedResult, output: routed)
        let explicitIDs = try await readIDs(explicitResult, output: explicit)
        XCTAssertEqual(routedIDs, explicitIDs, "same reads in each barcode")
        for (offset, barcode) in barcodes.enumerated() {
            XCTAssertEqual(routedIDs[barcode.id], Set((offset * 100..<(offset + 1) * 100).map { "r\($0)" }), barcode.id)
        }
        XCTAssertEqual(routedResult.manifest.unassigned.readCount, explicitResult.manifest.unassigned.readCount)
    }

    /// BIO-DEMUX-PARITY: a read that starts with D703 and whose next 8 bases spell D712 keeps D703. cutadapt names a
    /// read by its last match, so a second anchored search (`--times 2`) moved such reads to the barcode in their insert.
    func testInlineRunGivesAReadItsLeadingBarcodeWhenTheNextBasesSpellAnother() async throws {
        try await requireTools()
        let d703 = try XCTUnwrap(Self.kit.barcodes.first { $0.id == "D703" }).i7Sequence
        let d712 = try XCTUnwrap(Self.kit.barcodes.first { $0.id == "D712" }).i7Sequence
        let project = try project("SecondBarcode")
        let input = project.appendingPathComponent("second.fastq")
        try DemuxFloorFixtures.write(
            names: (0..<100).map { "s\($0)" }, leads: Array(repeating: d703 + d712, count: 100), seed: 13, to: input
        )
        let output = project.appendingPathComponent("explicit")
        let result = try await run(input, output: output, explicitCutadapt: true)
        let ids = try await readIDs(result, output: output)
        XCTAssertEqual(ids["D703"], Set((0..<100).map { "s\($0)" }), "each read keeps the barcode it starts with")
        XCTAssertNil(ids["D712"], "no read is given the barcode in its insert")
        XCTAssertEqual(result.manifest.unassigned.readCount, 0)
    }
}
