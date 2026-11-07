// DemultiplexSearchRouteTests.swift - The route owner reads the first read names before a run searches the bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L1, L4). A kit whose platform has `indexesInSeparateReads` was always searched in the
// read bases, whatever the read names carried (DEMUX-HEADER-INDEX-NOT-READ).

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexSearchRouteTests: XCTestCase {
    private func config(_ kit: BarcodeKitDefinition, engine: DemultiplexEngine? = nil) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            barcodeKit: kit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            engine: engine
        )
    }

    private func names(_ comments: [String]) -> [FASTQReadNameIndex] {
        comments.enumerated().map { FASTQReadNameIndex(rawName: "r\($0.offset) \($0.element)") }
    }

    private func label(_ route: DemultiplexSearchRoute) -> String {
        switch route {
        case .headerIndex: return "headerIndex"
        case .inline: return "inline"
        case .refuse(let words): return "refuse: \(words)"
        }
    }

    /// BIO-DEMUX-FLOOR item 1: the header route needs two or more kit barcodes present, each above its own chance
    /// ceiling and each the commonest index of the names near it.
    func testProbeTakesTheHeaderRouteOnlyWhenTwoKitBarcodesArePresent() {
        let kit = BarcodeKitRegistry.truseqSingleA
        let two = Array(repeating: "1:N:0:ATTACTCG", count: 900) + Array(repeating: "1:N:0:TCCGGAGA", count: 100)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(two))), "headerIndex")
        // One sample's names take the bases search, where the chance floor speaks for a file with no inline barcode.
        let d701 = Array(repeating: "1:N:0:ATTACTCG", count: 1_000)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(d701))), "inline")
        let library = Array(repeating: "1:N:0:GTCAGTAC", count: 1_000)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(library))), "inline")
        let sra = (1...1_000).map { "\($0) length=150" }
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(sra))), "inline")
        // Five names of each of two kit indexes among 990 library indexes sit within chance (a ceiling of 7 each).
        let few = Array(repeating: "1:N:0:GTCAGTAC", count: 990) + Array(repeating: "1:N:0:ATTACTCG", count: 5)
            + Array(repeating: "1:N:0:TCCGGAGA", count: 5)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(few))), "inline")
        // Names one mismatch from two barcodes are not those barcodes, since their commonest index is another.
        let near = Array(repeating: "1:N:0:ATTACTCA", count: 500) + Array(repeating: "1:N:0:TCCGGAGT", count: 500)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(near))), "inline")
        // An explicit engine searches the bases, as a recorded command of an earlier version ran.
        XCTAssertEqual(
            label(DemultiplexSearchRouteOwner.route(for: config(kit, engine: .cutadapt), names: names(two))), "inline"
        )
        // A long-read kit never reads the names.
        XCTAssertEqual(
            label(DemultiplexSearchRouteOwner.route(for: config(BarcodeKitDefinition(
                id: "ont", displayName: "ONT", vendor: "oxford-nanopore", platform: .oxfordNanopore,
                barcodes: [BarcodeEntry(id: "B1", i7Sequence: "ATTACTCG")]
            )), names: names(d701))),
            "inline"
        )
    }

    func testDualIndexKitRefusesOnlyWhenBothIndexesCollide() {
        func kit(_ pairs: [(String, String, String)]) -> BarcodeKitDefinition {
            BarcodeKitDefinition(
                id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
                barcodes: pairs.map { BarcodeEntry(id: $0.0, i7Sequence: $0.1, i5Sequence: $0.2) }
            )
        }
        // A combinatorial plate: four samples on one i7 with four i5s still splits (BIO, L6).
        let plate = kit([
            ("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTCG", "ATAGAGGC"),
            ("S3", "ATTACTCG", "CCTATCCT"), ("S4", "ATTACTCG", "GGCTCTGA"),
        ])
        let plateNames = names(["TATAGCCT", "ATAGAGGC", "CCTATCCT", "GGCTCTGA"].flatMap {
            Array(repeating: "1:N:0:ATTACTCG+\($0)", count: 250)
        })
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(plate), names: plateNames)), "headerIndex")

        // Two barcodes within two mismatches in both i7 and i5 refuse, and the words name both.
        // Each kit's names carry two of its own barcodes, so two are present (BIO-DEMUX-FLOOR item 1).
        func pairs(_ second: String) -> [FASTQReadNameIndex] {
            names(Array(repeating: "1:N:0:ATTACTCG+TATAGCCT", count: 500) + Array(repeating: "1:N:0:\(second)", count: 500))
        }
        let close = kit([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTAA", "TATAGCAA")])
        let words = label(DemultiplexSearchRouteOwner.route(for: config(close), names: pairs("ATTACTAA+TATAGCAA")))
        XCTAssertTrue(words.hasPrefix("refuse: Barcodes S1 and S2 differ at 4 bases"), words)
        XCTAssertTrue(words.contains("Correct the definition, or remove one of the two barcodes."), words)

        // Close in i7 only is no collision.
        let farI5 = kit([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTAA", "GGCTCTGA")])
        XCTAssertEqual(
            label(DemultiplexSearchRouteOwner.route(for: config(farI5), names: pairs("ATTACTAA+GGCTCTGA"))), "headerIndex"
        )

        // i5 matches as listed or reverse complemented.
        let reversed = names(["TATAGCCT", "ATAGAGGC"].flatMap {
            Array(repeating: "1:N:0:ATTACTCG+\(PlatformAdapters.reverseComplement($0))", count: 500)
        })
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(plate), names: reversed)), "headerIndex")
    }

    /// BIO-DEMUX-FLOOR item 7: a GBS lane whose one library index lies one mismatch from D701 is not D701.
    func testGBSLaneWhoseLibraryIndexLiesOneMismatchFromAKitBarcodeKeepsTheInlineSplit() {
        let gbs = names(Array(repeating: "1:N:0:AGTACTCG", count: 1_000))
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(BarcodeKitRegistry.truseqSingleA), names: gbs)), "inline")
    }

    /// BIO-DEMUX-FLOOR item 8: names of another 24-index kit, two of whose indexes lie one mismatch from D701 and D702.
    func testNamesOfAnotherKitTakeTheBasesSearch() {
        let kit = BarcodeKitRegistry.truseqSingleA
        let letters: [Character] = ["A", "C", "G", "T"]
        var generator = DemuxFloorSeededGenerator(seed: 24)
        var others: [String] = []
        while others.count < 22 {
            let index = String((0..<8).map { _ in letters[Int(generator.next() % 4)] })
            let far = (kit.barcodes.map(\.i7Sequence) + others).allSatisfy { DemuxFloorFixtures.mismatches(index, $0) >= 3 }
            if far { others.append(index) }
        }
        let indexes = ["AGTACTCG", "TCCGGAGT"] + others
        let comments = (0..<42).flatMap { _ in indexes.map { "1:N:0:\($0)" } }
        XCTAssertEqual(comments.count, 1_008)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(comments))), "inline")
    }

    /// BIO-DEMUX-FLOOR item 2: one barcode present in the first 1,000 names reads on to 10,000, so a second sample of
    /// 0.25% of the reads, with none in the first 1,000, still takes the header route.
    func testOneBarcodeInTheFirstThousandNamesReadsOnToTenThousand() async throws {
        let kit = BarcodeKitRegistry.truseqSingleA
        let comments = Array(repeating: "1:N:0:ATTACTCG", count: 1_000)
            + (0..<9_000).map { $0 % 360 == 0 ? "1:N:0:TCCGGAGA" : "1:N:0:ATTACTCG" }
        XCTAssertEqual(comments.filter { $0.hasSuffix("TCCGGAGA") }.count, 25)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(comments))), "headerIndex")
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(Array(comments.prefix(1_000))))), "inline")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demux-route-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: file) }
        try comments.enumerated().map { "@r\($0.offset) \($0.element)\nACGTACGT\n+\nIIIIIIII\n" }.joined()
            .write(to: file, atomically: true, encoding: .utf8)
        let route = await DemultiplexSearchRouteOwner.route(for: config(kit), input: file)
        XCTAssertEqual(label(route), "headerIndex")
    }

    private func writeRecords(_ comments: [String], tail: String = "", to file: URL) throws {
        try (comments.enumerated().map { "@r\($0.offset) \($0.element)\nACGTACGT\n+\nIIIIIIII\n" }.joined() + tail)
            .write(to: file, atomically: true, encoding: .utf8)
    }

    private var twoSamples: [String] {
        Array(repeating: "1:N:0:ATTACTCG", count: 900) + Array(repeating: "1:N:0:TCCGGAGA", count: 100)
    }

    /// DEMUXFLOOR-SWIFT SF1: the probe stops at 1,000 names, and at 10,000 when it reads on, so a bad record after
    /// them is never read (a read error routes to the bases search).
    func testProbeStopsReadingAtItsNameCount() async throws {
        let kit = BarcodeKitRegistry.truseqSingleA
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demux-route-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: file) }
        let bad = "this is not a FASTQ record\n" + (0..<50).map { "@x\($0) 1:N:0:ATTACTCG\nACGTACGT\n+\nIIIIIIII\n" }.joined()
        try writeRecords(twoSamples, tail: bad, to: file)
        let first = await DemultiplexSearchRouteOwner.route(for: config(kit), input: file)
        XCTAssertEqual(label(first), "headerIndex")
        let readOn = Array(repeating: "1:N:0:ATTACTCG", count: 1_000)
            + (0..<9_000).map { $0 % 360 == 0 ? "1:N:0:TCCGGAGA" : "1:N:0:ATTACTCG" }
        try writeRecords(readOn, tail: bad, to: file)
        let readingOn = await DemultiplexSearchRouteOwner.route(for: config(kit), input: file)
        XCTAssertEqual(label(readingOn), "headerIndex")
    }

    /// DEMUXFLOOR-SWIFT SF1: a gzip input gives the route of the plain file.
    func testGzipInputGivesTheRouteOfThePlainFile() async throws {
        let kit = BarcodeKitRegistry.truseqSingleA
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demux-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, comments, route) in [
            ("two", twoSamples, "headerIndex"), ("one", Array(repeating: "1:N:0:ATTACTCG", count: 1_000), "inline"),
        ] {
            let plain = folder.appendingPathComponent("\(name).fastq")
            try writeRecords(comments, to: plain)
            let gz = folder.appendingPathComponent("\(name).fastq.gz")
            try await SystemToolProbe.gzip(plain, to: gz)
            let probed = await DemultiplexSearchRouteOwner.route(for: config(kit), input: gz)
            XCTAssertEqual(label(probed), route, name)
        }
    }

    /// DEMUXFLOOR-SWIFT SF1: a bundle whose payload is `reads.fastq.gz`, the input the app sends, is probed through
    /// `resolveInputFASTQ` and takes the header route before the project and tool checks, which it does not need.
    func testBundleWithGzipPayloadTakesTheHeaderRouteBeforeTheProjectCheck() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demux-route-\(UUID().uuidString)")
        let bundle = folder.appendingPathComponent("Reads.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("reads.fastq")
        try writeRecords(twoSamples, to: plain)
        try await SystemToolProbe.gzip(plain, to: bundle.appendingPathComponent("reads.fastq.gz"))
        let route = try await DemultiplexingPipeline().preflight(config: DemultiplexConfig(
            inputURL: bundle, barcodeKit: BarcodeKitRegistry.truseqSingleA,
            outputDirectory: folder.appendingPathComponent("out", isDirectory: true)
        ))
        XCTAssertEqual(label(route), "headerIndex", "the bundle's reads were probed")
    }

    /// DEMUXFLOOR-SWIFT SF2: no built-in kit of a platform whose indexes sit in separate reads holds a colliding pair,
    /// since the collision words send a person to a definition a built-in kit does not let them edit.
    func testNoBuiltInKitOfAnIndexInSeparateReadsPlatformHoldsACollidingPair() {
        let kits = BarcodeKitRegistry.builtinKits().filter { $0.platform.indexesInSeparateReads }
        XCTAssertFalse(kits.isEmpty)
        for kit in kits {
            XCTAssertNil(DemultiplexSearchRouteOwner.collisionWords(for: kit), kit.id)
        }
    }

    /// DEMUXFLOOR-SWIFT SF3: names split evenly between two index shapes route the same way in every process. Half
    /// the names carry the kit's 8-base indexes and half a 6-base index, so the shape chosen decides the route; the
    /// longer shape wins the tie. Before the tie-break the answer followed the per-process dictionary order.
    func testEqualIndexShapesRouteTheSameWayInEveryProcess() {
        let comments = (0..<500).map { $0.isMultiple(of: 2) ? "1:N:0:ATTACTCG" : "1:N:0:TCCGGAGA" }
            + Array(repeating: "1:N:0:ACGTAC", count: 500)
        let route = DemultiplexSearchRouteOwner.route(for: config(BarcodeKitRegistry.truseqSingleA), names: names(comments))
        XCTAssertEqual(label(route), "headerIndex")
    }

    /// DEMUXFLOOR-BIO SF1 (ruling R1): a first-cycle N in a name's index is a no-call, so it agrees with the barcode in
    /// the commonest-index check, while a called base that differs is a rival and an index of only N is no index.
    func testFirstCycleNoCallsInTheNamesCountAsTheBarcode() {
        let kit = BarcodeKitRegistry.truseqSingleA
        func route(_ kit: BarcodeKitDefinition, _ comments: [String]) -> String {
            label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(comments)))
        }
        func named(_ index: String, _ count: Int) -> [String] { Array(repeating: "1:N:0:\(index)", count: count) }
        XCTAssertEqual(route(kit, named("NTTACTCG", 600) + named("NCCGGAGA", 400)), "headerIndex")
        XCTAssertEqual(route(kit, named("NTTACTCG", 450) + named("ATTACTCG", 100) + named("TCCGGAGA", 450)), "headerIndex")
        XCTAssertEqual(route(kit, named("AGTACTCG", 1_000)), "inline")
        XCTAssertEqual(route(kit, named("NNNNNNNN", 1_000)), "inline")
        // The first 1,000 names of DEMUXRUN-2's MiSeq file (b): NCTCGCTA 332 with no ACTCGCTA, NGATCAGT 190 against
        // CGATCAGT 144 (BIO's bio_check.py E1), with the run's three i7 indexes as the definition.
        let miseq = BarcodeKitDefinition(
            id: "miseq", displayName: "MiSeq sheet", vendor: "custom", platform: .illumina,
            barcodes: [("N716", "ACTCGCTA"), ("N727", "CGATCAGT"), ("N723", "TAGCGCTC")].map {
                BarcodeEntry(id: $0.0, i7Sequence: $0.1)
            }
        )
        let lane = named("NCTCGCTA", 332) + named("NGATCAGT", 190) + named("CGATCAGT", 144) + named("TAGCGCTC", 334)
        XCTAssertEqual(route(miseq, lane), "headerIndex")
    }

    func testChanceCeilingIsTheOneSidedBinomialBound() {
        XCTAssertEqual(DemultiplexChanceFloor.chanceCeiling(trials: 10_000, probability: 0, tail: 1e-6), 0)
        XCTAssertEqual(DemultiplexChanceFloor.chanceCeiling(trials: 10, probability: 1, tail: 1e-6), 10)
        for (trials, probability, tail) in [(10_000, 0.00078, 1e-6 / 12), (1_000, 0.0046, 1e-6), (2_000_000, 0.004, 1e-8)] {
            let ceiling = DemultiplexChanceFloor.chanceCeiling(trials: trials, probability: probability, tail: tail)
            XCTAssertGreaterThanOrEqual(
                DemultiplexChanceFloor.upperTail(trials: trials, probability: probability, from: ceiling), tail
            )
            XCTAssertLessThan(
                DemultiplexChanceFloor.upperTail(trials: trials, probability: probability, from: ceiling + 1), tail
            )
            XCTAssertGreaterThan(Double(ceiling), Double(trials) * probability)
        }
    }

    /// A custom definition is searched in the bases as a bare index, as an Illumina kit is, so its run reads the names
    /// too. On the real NextSeq 2000 pool of DEMUXRUN-2 (SRR41594715 to SRR41594719 with their own indexes as the
    /// definition) the floor's probe skipped the names and the run ended in the chance words.
    func testCustomDefinitionOnNamesCarryingItsIndexesTakesTheHeaderRoute() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demux-route-\(UUID().uuidString).csv")
        try "S1,GACGTCGA,TTGTTAAT\nS2,GACGTCGA,GAACAGTA\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let kit = try BarcodeKitRegistry.loadCustomKit(from: file, name: "sheet")
        let pool = (0..<1_000).map { $0.isMultiple(of: 2) ? "1:N:0:GACGTCGA+TTGTTAAT" : "1:N:0:GACGTCGA+GAACAGTA" }
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(pool))), "headerIndex")
        let sra = (1...1_000).map { "\($0) length=150" }
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(sra))), "inline")
    }

    /// QA SF2: an explicit `header-index` engine takes the header route with no probe, so it holds with no names, with the
    /// names of a GBS lane that the probe sends to the bases search when no engine is named, and for an input file that
    /// does not exist, which the probe would have read.
    func testExplicitHeaderIndexEngineTakesTheHeaderRouteWithoutTheProbe() async {
        let kit = BarcodeKitRegistry.truseqSingleA
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit, engine: .headerIndex), names: [])), "headerIndex")
        let gbs = names(Array(repeating: "1:N:0:AGTACTCG", count: 1_000))
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: gbs)), "inline")
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit, engine: .headerIndex), names: gbs)), "headerIndex")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("demux-route-\(UUID().uuidString).fastq")
        let unread = await DemultiplexSearchRouteOwner.route(for: config(kit, engine: .headerIndex), input: missing)
        XCTAssertEqual(label(unread), "headerIndex")
    }

    /// QA SF2: an explicit `header-index` engine on a kit whose two barcodes lie within two mismatches in both indexes
    /// refuses in the collision words, as the probe's route does for the same kit, so a Read Names pick never leaves the
    /// ambiguous reads of such a kit in Unassigned in silence.
    func testExplicitHeaderIndexEngineOnAKitWithCollidingBarcodesRefuses() throws {
        let close = BarcodeKitDefinition(
            id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
            barcodes: [("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTAA", "TATAGCAA")].map {
                BarcodeEntry(id: $0.0, i7Sequence: $0.1, i5Sequence: $0.2)
            }
        )
        let expected = try XCTUnwrap(DemultiplexSearchRouteOwner.collisionWords(for: close))
        let words = label(DemultiplexSearchRouteOwner.route(for: config(close, engine: .headerIndex), names: []))
        XCTAssertEqual(words, "refuse: \(expected)")
        XCTAssertTrue(words.hasPrefix("refuse: Barcodes S1 and S2 differ at 4 bases"), words)
        XCTAssertTrue(words.contains("Correct the definition, or remove one of the two barcodes."), words)
    }

    /// ARCH C1 (ruling ARCH-DEMUX-PLAN-CONTROL): a definition whose `# kit:` line names a built-in kit is probed with
    /// that kit's barcodes, so a plan of one sample, or one whose second sample has no reads in the first names, routes
    /// as the kit's own run on the same file does. The split still holds only the definition's rows.
    func testDefinitionOfOneSampleIsProbedWithItsKitsBarcodes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-kit-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# kit: truseq-single-a\nid,sequence,sample_name\nS1,ATTACTCG,Sample 1\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let definition = try BarcodeKitRegistry.loadCustomKit(from: url, name: "plan")
        let two = Array(repeating: "1:N:0:ATTACTCG", count: 900) + Array(repeating: "1:N:0:TCCGGAGA", count: 100)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(BarcodeKitRegistry.truseqSingleA), names: names(two))), "headerIndex")
        XCTAssertEqual(
            label(DemultiplexSearchRouteOwner.route(for: config(definition), names: names(two))), "headerIndex",
            "the definition of one sample was probed with its own row, not its kit's barcodes"
        )
        XCTAssertEqual(definition.barcodes.map(\.id), ["S1"])
    }
}
