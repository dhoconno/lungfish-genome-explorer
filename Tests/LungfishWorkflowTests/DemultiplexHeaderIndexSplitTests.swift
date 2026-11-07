// DemultiplexHeaderIndexSplitTests.swift - A run splits reads by the index bcl2fastq wrote in their names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN-3 (L4, L6). The floor stopped every file whose read names carry two or more of the kit's
// indexes. The header route now splits such a file by the index in each name, at most one mismatch in each index,
// with i5 read in one orientation for the whole file and both mates of a pair following their names. No tool runs.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexHeaderIndexSplitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-header-split")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A dual-index plate of `pairs` (id, i7, i5), as a sample sheet gives it.
    private func plate(_ pairs: [(String, String, String)]) -> BarcodeKitDefinition {
        BarcodeKitDefinition(
            id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
            barcodes: pairs.map { BarcodeEntry(id: $0.0, i7Sequence: $0.1, i5Sequence: $0.2) }
        )
    }

    /// A run with no engine named, so the route owner reads the names.
    private func run(
        _ input: URL, kit: BarcodeKitDefinition = BarcodeKitRegistry.truseqSingleA, output: URL
    ) async throws -> DemultiplexResult {
        let config = DemultiplexConfig(inputURL: input, barcodeKit: kit, outputDirectory: output, errorRate: 0.15, threads: 1)
        return try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
    }

    private func counts(_ result: DemultiplexResult) -> [String: Int] {
        Dictionary(result.manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) },
                   uniquingKeysWith: +)
    }

    /// The read IDs each published barcode bundle lists.
    private func readIDs(_ result: DemultiplexResult, output: URL) throws -> [String: Set<String>] {
        var ids: [String: Set<String>] = [:]
        for barcode in result.manifest.barcodes {
            let list = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
                .appendingPathComponent("read-ids.txt")
            ids[barcode.barcodeID] = Set(try String(contentsOf: list, encoding: .utf8).split(separator: "\n").map(String.init))
        }
        if let path = result.manifest.unassigned.bundleRelativePath {
            let list = output.appendingPathComponent(path, isDirectory: true).appendingPathComponent("read-ids.txt")
            ids["unassigned"] = Set(try String(contentsOf: list, encoding: .utf8).split(separator: "\n").map(String.init))
        }
        return ids
    }

    /// L6's mixed fixture: D701 holds its 1,000 names and the 20 one mismatch from it, D702 its 100, no other barcode
    /// any read, and the 10 names whose index is all `N` stay unassigned.
    func testTruSeqRunOnReadsWithTheIndexOnlyInTheirNamesSplitsThemByTheirNames() async throws {
        let names = DemuxFloorFixtures.mixedHeaderNames(seed: 11)
        let input = root.appendingPathComponent("mixed.fastq")
        try DemuxFloorFixtures.write(names: names, seed: 11, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let result = try await run(input, output: output)

        XCTAssertEqual(counts(result), ["D701": 1_020, "D702": 100])
        XCTAssertEqual(result.manifest.unassigned.readCount, 10)
        let ids = try readIDs(result, output: output)
        func readsNamed(_ suffix: String) -> Set<String> {
            Set(names.filter { $0.hasSuffix(suffix) }.map { String($0.split(separator: " ")[0]) })
        }
        XCTAssertEqual(ids["D702"], readsNamed("TCCGGAGA"))
        XCTAssertEqual(ids["D701"]?.count, 1_020)
        XCTAssertTrue(readsNamed("ATTACTCG").isSubset(of: ids["D701"] ?? []))
        let bundles = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
            .filter { $0.hasSuffix(".\(FASTQBundle.directoryExtension)") }.sorted()
        XCTAssertEqual(bundles, ["D701", "D702", "unassigned"].map { "\($0).\(FASTQBundle.directoryExtension)" })
    }

    /// i5 is read as listed or reverse complemented once for each file, by the majority of its first 1,000 names, so
    /// the 20 names that carry i5 the other way round stay unassigned, and each file of a bundle chooses its own.
    func testDualIndexRunChoosesTheI5OrientationOncePerFile() async throws {
        let kit = plate([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "TCCGGAGA", "ATAGAGGC")])
        func comments(_ count: Int, reversed: Bool) -> [String] {
            (0..<count).map { index in
                let barcode = kit.barcodes[index % 2]
                let i5 = barcode.i5Sequence!
                return "1:N:0:\(barcode.i7Sequence)+\(reversed ? PlatformAdapters.reverseComplement(i5) : i5)"
            }
        }
        let file = comments(20, reversed: false) + comments(280, reversed: true)
        let input = root.appendingPathComponent("dual.fastq")
        try DemuxFloorFixtures.write(names: file.enumerated().map { "r\($0.offset) \($0.element)" }, seed: 3, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let result = try await run(input, kit: kit, output: output)
        XCTAssertEqual(counts(result), ["S1": 140, "S2": 140])
        XCTAssertEqual(result.manifest.unassigned.readCount, 20)
        XCTAssertEqual(try readIDs(result, output: output)["unassigned"], Set((0..<20).map { "r\($0)" }))

        // A bundle of two files: the first carries i5 as listed and the second reverse complemented.
        let bundle = root.appendingPathComponent("pool.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        for (name, reversed) in [("a", false), ("b", true)] {
            try DemuxFloorFixtures.write(
                names: comments(100, reversed: reversed).enumerated().map { "\(name)\($0.offset) \($0.element)" },
                seed: reversed ? 5 : 4, to: chunks.appendingPathComponent("\(name).fastq")
            )
        }
        let files = ["a", "b"].map {
            "{\"filename\": \"chunks/\($0).fastq\", \"originalPath\": \"/tmp/\($0).fastq\", \"sizeBytes\": 1, \"isSymlink\": false}"
        }
        try "{\"version\": 1, \"files\": [\(files.joined(separator: ", "))]}"
            .write(to: bundle.appendingPathComponent("source-files.json"), atomically: true, encoding: .utf8)
        let pooled = try await run(bundle, kit: kit, output: root.appendingPathComponent("pooled", isDirectory: true))
        XCTAssertEqual(pooled.manifest.inputReadCount, 200)
        XCTAssertEqual(counts(pooled), ["S1": 100, "S2": 100])
        XCTAssertEqual(pooled.manifest.unassigned.readCount, 0)
    }

    /// BIO's L6 amendment: four samples on one i7 with four i5s split, 100 reads each, and no read goes elsewhere.
    func testCombinatorialDualIndexPlateSharingAnI7Splits() async throws {
        let kit = plate([
            ("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTCG", "ATAGAGGC"),
            ("S3", "ATTACTCG", "CCTATCCT"), ("S4", "ATTACTCG", "GGCTCTGA"),
        ])
        let names = (0..<400).map { "r\($0) 1:N:0:ATTACTCG+\(kit.barcodes[$0 % 4].i5Sequence!)" }
        let input = root.appendingPathComponent("plate.fastq")
        try DemuxFloorFixtures.write(names: names, seed: 8, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let result = try await run(input, kit: kit, output: output)
        XCTAssertEqual(counts(result), ["S1": 100, "S2": 100, "S3": 100, "S4": 100])
        XCTAssertEqual(result.manifest.unassigned.readCount, 0)
        let ids = try readIDs(result, output: output)
        for (offset, barcode) in kit.barcodes.enumerated() {
            XCTAssertEqual(ids[barcode.id], Set(stride(from: offset, to: 400, by: 4).map { "r\($0)" }), barcode.id)
        }
    }

    /// BIO SF2: the i5 rules no other split test reaches. One mismatch in i5 is allowed and so is a no-call `N`, two are
    /// not, a hopped pair (one barcode's i7 with another's i5) stays unassigned, and a name with no i5 is called by its i7.
    func testDualIndexNamesAllowOneMismatchInI5AndLeaveAHoppedPairUnassigned() async throws {
        let kit = plate([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "TCCGGAGA", "ATAGAGGC")])
        var comments = Array(repeating: "1:N:0:ATTACTCG+TATAGCCT", count: 100)
        comments += Array(repeating: "1:N:0:TCCGGAGA+ATAGAGGC", count: 100)
        // r200 to r239, 10 each: S1's i7 with an i5 one substitution away, one with an N, two substitutions away, and S2's i5.
        for i5 in ["TATAGCCA", "NATAGCCT", "TATAGCAA", "ATAGAGGC"] {
            comments += Array(repeating: "1:N:0:ATTACTCG+\(i5)", count: 10)
        }
        comments += Array(repeating: "1:N:0:ATTACTCG", count: 10) // r240 to r249, no i5
        let input = root.appendingPathComponent("hopped.fastq")
        try DemuxFloorFixtures.write(names: comments.enumerated().map { "r\($0.offset) \($0.element)" }, seed: 15, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let result = try await run(input, kit: kit, output: output)
        XCTAssertEqual(counts(result), ["S1": 130, "S2": 100])
        XCTAssertEqual(result.manifest.unassigned.readCount, 20)
        XCTAssertEqual(try readIDs(result, output: output)["unassigned"], Set((220..<240).map { "r\($0)" }))
    }

    /// UX SF3: a Read Names run whose names carry no index of the kit stops in words and publishes nothing, so a person
    /// is not left with every read in Unassigned and no sentence that says why or what to try.
    func testReadNamesRunOnNamesWithNoIndexOfTheKitEndsInWordsAndPublishesNothing() async throws {
        let kit = BarcodeKitRegistry.truseqSingleA
        for barcode in kit.barcodes {
            XCTAssertGreaterThan(DemuxFloorFixtures.mismatches("GGGGGGGG", barcode.i7Sequence), 2, barcode.id)
        }
        let input = root.appendingPathComponent("no-index.fastq")
        try DemuxFloorFixtures.write(names: (0..<200).map { "r\($0) 1:N:0:GGGGGGGG" }, seed: 14, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: input, barcodeKit: kit, outputDirectory: output, errorRate: 0.15, threads: 1, engine: .headerIndex
        )
        do {
            _ = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
            XCTFail("the run published a result with every read in Unassigned")
        } catch {
            XCTAssertTrue(String(describing: error).hasPrefix("noReadNameIndex("), "\(error)")
            let words = error.localizedDescription
            XCTAssertTrue(words.hasPrefix("No read name carried an index of \(kit.displayName)"), words)
            XCTAssertTrue(words.hasSuffix("or import this file as one sample."), words)
        }
        let bundles = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
            .filter { $0.hasSuffix(".\(FASTQBundle.directoryExtension)") }
        XCTAssertEqual(bundles, [], "no bundle is published")
    }

    /// Both Ends anchors the two indexes of a search of the read bases. The split by the names searches no base, so a
    /// dual plate at 5' End splits by its names, and the same plate on names with no index still refuses (Finding 2).
    func testDualPlateAtFivePrimeEndSplitsByItsNames() async throws {
        let kit = plate([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "TCCGGAGA", "ATAGAGGC")])
        func config(_ input: URL, _ output: String) -> DemultiplexConfig {
            DemultiplexConfig(inputURL: input, barcodeKit: kit, outputDirectory: root.appendingPathComponent(output, isDirectory: true),
                              barcodeLocation: .fivePrime, errorRate: 0.15, threads: 1)
        }
        let names = (0..<200).map { "r\($0) 1:N:0:\(kit.barcodes[$0 % 2].i7Sequence)+\(kit.barcodes[$0 % 2].i5Sequence!)" }
        let input = root.appendingPathComponent("plate.fastq")
        try DemuxFloorFixtures.write(names: names, seed: 12, to: input)
        let result = try await DemultiplexingPipeline().run(config: config(input, "out"), progress: { _, _ in })
        XCTAssertEqual(counts(result), ["S1": 100, "S2": 100])

        let bare = root.appendingPathComponent("bare.fastq")
        try DemuxFloorFixtures.write(names: (0..<200).map { "r\($0)" }, seed: 13, to: bare)
        do {
            try await DemultiplexingPipeline().preflight(config: config(bare, "bare-out"))
            XCTFail("a search of the bases at 5' End leaves the plate's second index free")
        } catch DemultiplexError.dualKitNeedsBothEnds(let kitName) {
            XCTAssertEqual(kitName, kit.displayName)
        }
    }

    /// Both mates of an interleaved pair follow their names, and a pair whose second mate's index is all `N` follows
    /// its first mate (A9, D6).
    func testMatesOfAnInterleavedPairFollowTheirNames() async throws {
        var names: [String] = []
        for pair in 0..<210 {
            let index = pair < 100 || pair >= 200 ? "ATTACTCG" : "TCCGGAGA"
            names += ["p\(pair) 1:N:0:\(index)", "p\(pair) 2:N:0:\(pair >= 200 ? "NNNNNNNN" : index)"]
        }
        let input = root.appendingPathComponent("pairs.fastq")
        try DemuxFloorFixtures.write(names: names, seed: 6, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let result = try await run(input, output: output)
        XCTAssertEqual(counts(result), ["D701": 220, "D702": 200])
        XCTAssertEqual(result.manifest.unassigned.readCount, 0)
        let mateCalls = try XCTUnwrap(result.manifest.mateCalls)
        XCTAssertEqual(mateCalls.pairs, 210)
        XCTAssertEqual(mateCalls.bothMatesAgree, 200)
        XCTAssertEqual(mateCalls.oneMateCalled, 10)
    }

    /// PAIREDROOT: a root of R1 and R2 files with no `source-files.json` is one sample's pair. A call on each file
    /// alone could put the two mates of one pair in different barcodes, so the split refuses in the words of the
    /// exact-barcode engines and writes nothing.
    func testRootOfR1AndR2FilesWithIndexedNamesRefusesInTheExactEnginesWords() async throws {
        let bundle = root.appendingPathComponent("s.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for mate in 1...2 {
            let names = (0..<200).map { "p\($0) \(mate):N:0:\($0.isMultiple(of: 2) ? "ATTACTCG" : "TCCGGAGA")" }
            try DemuxFloorFixtures.write(
                names: names, seed: UInt64(20 + mate), to: bundle.appendingPathComponent("s_R\(mate).fastq")
            )
        }
        let output = root.appendingPathComponent("out", isDirectory: true)
        do {
            _ = try await run(bundle, output: output)
            XCTFail("the split ran on a root of R1 and R2 files")
        } catch DemultiplexError.fileSetNeedsInterleaving(_, let fileNames) {
            XCTAssertEqual(fileNames, ["s_R1.fastq", "s_R2.fastq"])
        }
        let visible = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(visible, [], "nothing is written before the refusal")
    }
}
