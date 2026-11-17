// DemultiplexSaturatedKitTests.swift - A kit the chance check cannot judge makes no sample files without an opt-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-SATKIT, backlog DEMUX-FLOOR-SATURATED-KIT (ruling BIO-DEMUX-THREE items 2 to 6, section 1).
// A kit whose uniform chance share reaches 0.5 cannot measure the null on its own unassigned reads, so the floor fell back to
// random bases, which real read starts pass. QA's 384 kit published on 87 of 87 real cuts (BIO-DEMUX-NULL:23). Preflight
// now refuses such a kit unless the person keeps the unchecked samples.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexSaturatedKitTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("satkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// QA's 384 kit (`DemultiplexChanceFloorTests.swift:58-98`): 192 barcodes of 4 bases and 192 of 5, prefix free.
    static func qa384Barcodes() -> [String] {
        let letters = Array("ACGT")
        let fours = (0..<256).map { value in String((0..<4).map { letters[(value >> (2 * (3 - $0))) & 3] }) }
        let fives = Array(fours.suffix(64).flatMap { prefix in letters.map { prefix + String($0) } }.prefix(192))
        return Array(fours.prefix(192)) + fives
    }

    /// The kit as a Custom Definition, read the way `lungfish-cli fastq demultiplex --kit <file>` and the dialog read it.
    static func definitionKit(_ barcodes: [String], name: String) throws -> BarcodeKitDefinition {
        let rows = barcodes.enumerated().map { "BC\(String(format: "%03d", $0.offset + 1)),\($0.element)" }
        return try BarcodeKitRegistry.loadCustomKit(text: (["id,sequence"] + rows).joined(separator: "\n") + "\n", name: name)
    }

    static func fixtureStarts(_ name: String) throws -> [String] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/demux-null/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// A project that holds `starts` as single reads, or as interleaved mates `/1` and `/2` when `paired`.
    private func project(starts: [String], paired: Bool = false) throws -> (input: URL, output: URL) {
        let project = folder.appendingPathComponent("satkit.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var text = ""
        text.reserveCapacity(starts.count * 48)
        for (index, start) in starts.enumerated() {
            let name = paired ? "p\(index / 2)/\(index % 2 + 1)" : "r\(index)"
            text += "@\(name)\n\(start)\n+\n\(String(repeating: "I", count: start.count))\n"
        }
        let input = project.appendingPathComponent("reads.fastq")
        try text.write(to: input, atomically: true, encoding: .utf8)
        return (input, project.appendingPathComponent("Analyses/demultiplex", isDirectory: true))
    }

    private func config(
        kit: BarcodeKitDefinition, files: (input: URL, output: URL), errorRate: Double = 0.15, optIn: Bool = false
    ) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: files.input, barcodeKit: kit, outputDirectory: files.output, barcodeLocation: .bothEnds,
            errorRate: errorRate, engine: .cutadapt, keepsUncheckedSamples: optIn
        )
    }

    // MARK: - The red test (BIO-DEMUX-THREE item 5)

    /// QA's 384 kit on 100,000 real E. coli read starts, which carry no barcode, with no opt-in. At the base preflight passed
    /// and the run published the chance matches as samples. It must refuse in words that name the option, and write nothing.
    func testQAs384KitOnRealReadStartsIsRefusedWithoutTheOptIn() async throws {
        let kit = try Self.definitionKit(Self.qa384Barcodes(), name: "QA 384")
        let files = try project(starts: Self.fixtureStarts("SRR2584863-R1-first100000-starts12.txt"))
        let config = config(kit: kit, files: files)
        do {
            try await DemultiplexingPipeline().preflight(config: config)
            XCTFail("the 384 kit passed preflight, so the run publishes chance matches as samples")
        } catch DemultiplexError.chanceCheckCannotJudgeKit(let kitName) {
            XCTAssertEqual(kitName, "QA 384")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path), "a refusal writes nothing")
        let words = try XCTUnwrap(DemultiplexError.chanceCheckCannotJudgeKit(kitName: "QA 384").errorDescription)
        XCTAssertTrue(words.contains("cannot tell this pool from reads that carry no barcode"), words)
        XCTAssertTrue(words.contains("--keep-unchecked-samples"), words)
        XCTAssertTrue(words.contains("nothing was run"), words)
    }

    /// With the opt-in the same run passes preflight, as every run did at the base.
    func testQAs384KitWithTheOptInPassesPreflight() async throws {
        let kit = try Self.definitionKit(Self.qa384Barcodes(), name: "QA 384")
        let files = try project(starts: Self.fixtureStarts("SRR2584863-R1-first100000-starts12.txt"))
        let route = try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: files, optIn: true))
        XCTAssertFalse(route.isHeaderIndex)
    }

    /// The defect's cause, a pin. The kit's uniform share is 0.94, so the floor cannot measure the null on the unassigned
    /// reads, falls back to random bases, and the real starts, which are not uniform, beat it: the run publishes.
    func testTheFloorAloneLetsThe384KitPublishOnRealReadStarts() throws {
        let barcodes = Self.qa384Barcodes()
        let patterns = Dictionary(uniqueKeysWithValues: barcodes.map { ($0, ["^\($0)"]) })
        let fours = Set(barcodes.filter { $0.count == 4 })
        let fives = Set(barcodes.filter { $0.count == 5 })
        let starts = try Self.fixtureStarts("SRR2584863-R1-first100000-starts12.txt")
        var counts: [String: Int] = [:]
        var tally = DemultiplexChanceFloor.StartTally(patterns: patterns, errorRate: 0.15, allowsIndels: true)
        var unassigned = 0
        for start in starts {
            // -e 0.15 allows no error on 4 or 5 bases, so a read takes the barcode its first bases spell.
            if fours.contains(String(start.prefix(4))) {
                counts[String(start.prefix(4)), default: 0] += 1
            } else if fives.contains(String(start.prefix(5))) {
                counts[String(start.prefix(5)), default: 0] += 1
            } else {
                unassigned += 1
                tally.add(codes: DemultiplexChanceFloor.baseCodes(start))
            }
        }
        let outcome = DemultiplexChanceFloor.evaluate(
            patterns: patterns, counts: counts, readsSearched: starts.count, unassigned: unassigned, errorRate: 0.15,
            allowsIndels: true, pairedFragments: false, unassignedStarts: [tally]
        )
        print("SATKIT 384 kit on SRR2584863: \(unassigned) unassigned, \(outcome.barcodes.filter(\.beatsTheFloor).count) beat")
        XCTAssertEqual(outcome.null, .randomBases, "the kit cannot measure its own null")
        XCTAssertTrue(outcome.anyBarcodeBeatsTheFloor, "reads with no barcode publish as samples")
    }

    // MARK: - The refusal pass (SAD:106, BIO-DEMUX-THREE item 6)

    /// No built-in kit is refused. The refusal reads only a kit searched as its bare barcodes, the search the floor judges.
    /// On the lines cutadapt searches for such a kit, at error rates 0 and 0.15, at Both Ends and 5' End, its share stays
    /// under 0.5 even as fragments of two mates, the larger share, and the refusal itself passes every built-in kit. A kit
    /// searched inside its flanking adapters is never read, and its long lines with many errors are not worked out here.
    func testEveryBuiltInKitHasAShareUnderTheSaturatedShare() async throws {
        var shares: [(kit: String, share: Double)] = []
        var unbuilt: [String] = []
        var refused: [String] = []
        let input = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        for kit in BarcodeKitRegistry.builtinKits() {
            for errorRate in [0, 0.15] {
                for location in [BarcodeLocation.bothEnds, .fivePrime] {
                    let config = DemultiplexConfig(
                        inputURL: input, barcodeKit: kit, outputDirectory: folder, barcodeLocation: location,
                        errorRate: errorRate, engine: .cutadapt
                    )
                    let work = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    let pipeline = DemultiplexingPipeline()
                    guard let adapters = try? await pipeline.createAdapterConfiguration(for: config, workDirectory: work) else {
                        unbuilt.append("\(kit.id) at \(errorRate)")
                        continue
                    }
                    let setting = "\(kit.id) \(location) e\(errorRate)"
                    do {
                        try pipeline.requireChanceCheckableKit(
                            config: config, adapterFASTA: adapters.adapterFASTA, inputFASTQ: input
                        )
                    } catch {
                        refused.append(setting)
                    }
                    guard config.demuxAdapterContext is BareAdapterContext else { continue }
                    let share = DemultiplexChanceFloor.uniformKitShare(
                        patterns: try pipeline.chancePatterns(in: adapters.adapterFASTA), errorRate: config.effectiveErrorRate,
                        allowsIndels: true, unit: 2
                    )
                    shares.append((setting, share))
                }
            }
        }
        let largest = shares.max { $0.share < $1.share }
        print("SATKIT refusal pass: \(shares.count) bare kit settings, largest \(largest.map { "\($0.kit) \($0.share)" } ?? "none"), unbuilt \(Set(unbuilt).sorted())")
        XCTAssertGreaterThan(shares.count, 20)
        XCTAssertEqual(refused, [], "the refusal passes every built-in kit")
        XCTAssertEqual(shares.filter { $0.share >= DemultiplexChanceFloor.saturatedKitShare }.map(\.kit), [])
    }

    /// The refusal reads the kit and the error rate, never the reads, so QA's 384 kit is refused on the other real starts.
    func testQAs384KitIsRefusedOnTheNextSeqAndAmpliconStartsToo() async throws {
        let kit = try Self.definitionKit(Self.qa384Barcodes(), name: "QA 384")
        for name in ["SRR41594715-R1-first10000-starts12.txt", "SRR36291587-R1-first10000-starts12.txt"] {
            let files = try project(starts: Self.fixtureStarts(name))
            do {
                try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: files))
                XCTFail("\(name) passed preflight")
            } catch DemultiplexError.chanceCheckCannotJudgeKit {}
            try FileManager.default.removeItem(at: files.input.deletingLastPathComponent())
        }
    }

    /// A kit of 100 four-base barcodes holds 0.39 of single reads and 0.78 of two-mate fragments. A run that places mates
    /// judges fragments, so an interleaved file is refused and a file of single reads is not, and the refusal is exact.
    func testAPairedFileIsJudgedAsFragments() async throws {
        let fours = Array(Self.qa384Barcodes().prefix(100))
        let kit = try Self.definitionKit(fours, name: "Short 100")
        let starts = Array(try Self.fixtureStarts("SRR2584863-R1-first100000-starts12.txt").prefix(2_000))
        let paired = try project(starts: starts, paired: true)
        do {
            try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: paired))
            XCTFail("an interleaved file passed preflight with a kit that holds 0.78 of fragments")
        } catch DemultiplexError.chanceCheckCannotJudgeKit {}
        try FileManager.default.removeItem(at: paired.input.deletingLastPathComponent())
        let single = try project(starts: starts)
        try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: single))
    }

    // MARK: - The opt-in (BIO-DEMUX-THREE items 3 and 5)

    /// With the opt-in the floor gives the base's files, the barcodes the floor of random bases passes, and names the
    /// null `saturated-kit`. It is the floor the run calls, on the unassigned reads of the real starts.
    func testTheOptInKeepsTheBasesFilesAndNamesTheSaturatedNull() async throws {
        let barcodes = Self.qa384Barcodes()
        let kit = try Self.definitionKit(barcodes, name: "QA 384")
        let starts = try Self.fixtureStarts("SRR2584863-R1-first100000-starts12.txt")
        let files = try project(starts: starts)
        let config = config(kit: kit, files: files, optIn: true)
        let pipeline = DemultiplexingPipeline()
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let adapters = try await pipeline.createAdapterConfiguration(for: config, workDirectory: work)
        let byID = Dictionary(uniqueKeysWithValues: kit.barcodes.map { ($0.i7Sequence.uppercased(), $0.id) })
        var counts: [String: Int] = [:]
        var unassignedText = ""
        for (index, start) in starts.enumerated() {
            if let id = byID[String(start.prefix(4))] ?? byID[String(start.prefix(5))] {
                counts[id, default: 0] += 1
            } else {
                unassignedText += "@u\(index)\n\(start)\n+\n\(String(repeating: "I", count: start.count))\n"
            }
        }
        let unassignedURL = work.appendingPathComponent("unassigned.fastq")
        try unassignedText.write(to: unassignedURL, atomically: true, encoding: .utf8)
        let unassigned = starts.count - counts.values.reduce(0, +)
        let floor = try await pipeline.requireBarcodesAboveChance(
            config: config, adapterFASTA: adapters.adapterFASTA, counts: counts, readsSearched: starts.count,
            unassigned: unassigned, paired: false, unassignedReadsURL: unassignedURL
        )
        let outcome = try XCTUnwrap(floor)
        XCTAssertEqual(outcome.null, .saturatedKit)
        XCTAssertEqual(outcome.null.rawValue, "saturated-kit")
        let base = DemultiplexChanceFloor.evaluate(
            patterns: try pipeline.chancePatterns(in: adapters.adapterFASTA), counts: counts, readsSearched: starts.count,
            unassigned: unassigned, errorRate: 0.15, allowsIndels: true, pairedFragments: false
        )
        XCTAssertEqual(outcome.barcodes, base.barcodes, "the base's floor of random bases, so the base's files")
        XCTAssertTrue(outcome.anyBarcodeBeatsTheFloor)
        XCTAssertEqual(
            DemultiplexChanceWords.floorLimit(publishedBarcodes: 1, null: outcome.null), DemultiplexChanceWords.uncheckedKitLine
        )
        XCTAssertEqual(
            DemultiplexChanceWords.floorLimit(publishedBarcodes: 1, null: .startComposition),
            DemultiplexChanceWords.notInPoolLimit(publishedBarcodes: 1), "a kit the floor judges keeps its limit line"
        )
    }
}
