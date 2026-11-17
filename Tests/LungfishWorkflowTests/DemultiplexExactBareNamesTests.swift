// DemultiplexExactBareNamesTests.swift - Exact Bare Barcode makes no chance samples from barcodes that sit in the read names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-EXACTBARE-NAMES, backlog DEMUX-EXACT-BARE-NO-FLOOR, the names case (ruling BIO-DEMUX-THREE
// item 7 and section 2a). Exact Bare Barcode searches the read sequences and checks no chance, and naming it skips the read-name
// probe of the route owner. Reads whose barcodes sit only in their names gave every barcode of a list a sample file of chance
// matches. Preflight now reads the first names as the route owner does and refuses when two or more of the kit's barcodes are
// present there, unless the person keeps the unchecked samples. No tool runs.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexExactBareNamesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-exactbare-names")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// A custom list of 12 barcodes of 8 bases (the i7 of TruSeq D701 to D712), a definition with no `# kit:` line.
    static let twelve = ["ATTACTCG", "TCCGGAGA", "CGCTCATT", "GAGATTCC", "ATTCAGAA", "GAATTCGT", "CTGAAGCT", "TAATGCGC",
                         "CGGCTATG", "TCCGCGAA", "TCTCGCGC", "AGCGATAG"]

    /// The list as a Custom Definition, read the way `lungfish-cli fastq demultiplex --kit <file>` and the dialog read it.
    static func definitionKit(_ barcodes: [String] = twelve, name: String = "Twelve") throws -> BarcodeKitDefinition {
        let rows = barcodes.enumerated().map { "BC\(String(format: "%02d", $0.offset + 1)),\($0.element)" }
        return try BarcodeKitRegistry.loadCustomKit(text: (["id,sequence"] + rows).joined(separator: "\n") + "\n", name: name)
    }

    private func config(_ input: URL, kit: BarcodeKitDefinition, output: String = "out", optIn: Bool = false) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: input, barcodeKit: kit, outputDirectory: root.appendingPathComponent(output, isDirectory: true),
            threads: 1, engine: .exactBareBarcode, keepsUncheckedSamples: optIn
        )
    }

    /// 2,000 seeded reads of 150 random bases named `r<i> 1:N:0:<barcode>`, alternating BC01 and BC02 (item 7). At about
    /// 0.435% a read for each barcode, both strands, each barcode gets about 8.7 chance reads.
    private func namesFile() throws -> URL {
        let input = root.appendingPathComponent("names.fastq")
        try DemuxFloorFixtures.write(names: (0..<2_000).map { "r\($0) 1:N:0:\(Self.twelve[$0 % 2])" }, seed: 17, to: input)
        return input
    }

    private func bundles(in output: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
            .filter { $0.hasSuffix(".\(FASTQBundle.directoryExtension)") }
    }

    private func counts(_ result: DemultiplexResult) -> [String: Int] {
        Dictionary(result.manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) },
                   uniquingKeysWith: +)
    }

    // MARK: - The red test (BIO-DEMUX-THREE item 7)

    /// At the base the run searched the sequences for barcodes that sit in the names and made a sample file for each of the
    /// 12. It must refuse before any file, in words that say the barcodes are in the read names and name the split by them.
    func testExactBareOnReadsWhoseBarcodesSitInTheirNamesIsRefusedBeforeAnyFile() async throws {
        let config = config(try namesFile(), kit: try Self.definitionKit())
        do {
            let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
            XCTFail("Exact Bare made \(counts(result).count) sample files from chance matches of barcodes in the read names")
        } catch {
            XCTAssertTrue(String(describing: error).hasPrefix("exactBareBarcodesInReadNames("), "\(error)")
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("read names carry"), words)
            XCTAssertTrue(words.contains("--engine header-index"), words)
            XCTAssertTrue(words.contains("--keep-unchecked-samples"), words)
            XCTAssertTrue(words.contains("nothing was run"), words)
        }
        XCTAssertEqual(bundles(in: config.outputDirectory), [], "a refusal writes no sample file")
    }

    /// The opt-in runs the search of the sequences as the base ran it, so the same file makes the base's 12 sample files.
    func testWithTheOptInTheSearchRunsAsTheBaseRanIt() async throws {
        let config = config(try namesFile(), kit: try Self.definitionKit(), optIn: true)
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        let counts = counts(result)
        print("EXACTBARE-NAMES opt-in, chance reads by barcode: \(counts.sorted { $0.key < $1.key })")
        XCTAssertEqual(counts.count, 12, "the base made a sample file for each of the 12 barcodes")
        XCTAssertEqual(result.manifest.inputReadCount, 2_000)
    }

    // MARK: - The green pin

    /// Barcodes inline at the start of each read, with names that carry no index, run as they ran at the base.
    func testInlineBarcodesWithNamesThatCarryNoIndexRunAsToday() async throws {
        let input = root.appendingPathComponent("inline.fastq")
        try DemuxFloorFixtures.write(
            names: (0..<2_000).map { "r\($0)" }, leads: (0..<2_000).map { Self.twelve[$0 % 2] }, seed: 17, to: input
        )
        let result = try await DemultiplexingPipeline().run(config: config(input, kit: try Self.definitionKit()), progress: { _, _ in })
        let counts = counts(result)
        print("EXACTBARE-NAMES inline pin: \(counts.sorted { $0.key < $1.key }), unassigned \(result.manifest.unassigned.readCount)")
        XCTAssertGreaterThanOrEqual(counts["BC01"] ?? 0, 950)
        XCTAssertGreaterThanOrEqual(counts["BC02"] ?? 0, 950)
        XCTAssertEqual(counts.values.reduce(0, +) + result.manifest.unassigned.readCount, 2_000)
    }

    // MARK: - Refusal pass (SAD:106)

    /// The files of `DemultiplexHeaderIndexSplitTests` and `DemultiplexHeaderIndexFloorConformanceTests`, run through the
    /// Exact Bare preflight with a definition of TruSeq Single A's i7 sequences. A file whose names carry two or more of its
    /// barcodes is refused, and a file with one barcode, one library index, an index of no barcode or no index passes.
    func testRefusalPassOnTheFilesOfTheHeaderIndexTests() async throws {
        let kit = try Self.definitionKit(BarcodeKitRegistry.truseqSingleA.barcodes.map(\.i7Sequence), name: "TruSeq i7")
        let s1 = ("ATTACTCG", "TATAGCCT"), s2 = ("TCCGGAGA", "ATAGAGGC")
        func numbered(_ comments: [String]) -> [String] { comments.enumerated().map { "r\($0.offset) \($0.element)" } }
        var dual = (0..<20).map { $0 % 2 == 0 ? "1:N:0:\(s1.0)+\(s1.1)" : "1:N:0:\(s2.0)+\(s2.1)" }
        dual += (0..<280).map {
            $0 % 2 == 0 ? "1:N:0:\(s1.0)+\(PlatformAdapters.reverseComplement(s1.1))"
                : "1:N:0:\(s2.0)+\(PlatformAdapters.reverseComplement(s2.1))"
        }
        var hopped = Array(repeating: "1:N:0:\(s1.0)+\(s1.1)", count: 100) + Array(repeating: "1:N:0:\(s2.0)+\(s2.1)", count: 100)
        for i5 in ["TATAGCCA", "NATAGCCT", "TATAGCAA", "ATAGAGGC"] { hopped += Array(repeating: "1:N:0:\(s1.0)+\(i5)", count: 10) }
        hopped += Array(repeating: "1:N:0:\(s1.0)", count: 10)
        var pairs: [String] = []
        for pair in 0..<210 {
            let index = pair < 100 || pair >= 200 ? s1.0 : s2.0
            pairs += ["p\(pair) 1:N:0:\(index)", "p\(pair) 2:N:0:\(pair >= 200 ? "NNNNNNNN" : index)"]
        }
        let agree = ["ATTACTCG", "TCCGGAGA", "CGCTCATT"].flatMap { Array(repeating: $0, count: 100) }
        let plateI5s = ["TATAGCCT", "ATAGAGGC", "CCTATCCT", "GGCTCTGA"]
        let files: [(name: String, names: [String], leads: [String], refused: Bool)] = [
            ("mixed", DemuxFloorFixtures.mixedHeaderNames(seed: 11), [], true),
            ("dual", numbered(dual), [], true),
            ("hopped", numbered(hopped), [], true),
            ("pairs", pairs, [], true),
            ("agree", numbered(agree.map { "1:N:0:\($0)" }), agree, true),
            ("plate-one-i7", (0..<400).map { "r\($0) 1:N:0:\(s1.0)+\(plateI5s[$0 % 4])" }, [], false),
            ("one-sample", (0..<10_000).map { "r\($0) 1:N:0:\(s1.0)" }, [], false),
            ("library-index", (0..<200).map { "r\($0) 1:N:0:GTCAGTAC" },
             Array(repeating: s1.0, count: 80) + Array(repeating: s2.0, count: 80), false),
            ("empty-index", (0..<10_000).map { "r\($0) 1:N:0:GGGGGGGG" }, [], false),
            ("no-index", (1...10_000).map { "SRR000001.\($0) \($0) length=150" }, [], false),
        ]
        for file in files {
            let input = root.appendingPathComponent("\(file.name).fastq")
            try DemuxFloorFixtures.write(names: file.names, leads: file.leads, seed: 5, to: input)
            do {
                try await DemultiplexingPipeline().preflight(config: config(input, kit: kit, output: file.name))
                XCTAssertFalse(file.refused, "\(file.name): its names carry two or more barcodes and it passed")
            } catch {
                XCTAssertTrue(file.refused, "\(file.name): refused, \(error)")
                XCTAssertTrue(String(describing: error).hasPrefix("exactBareBarcodesInReadNames("), "\(file.name): \(error)")
            }
        }
    }
}
