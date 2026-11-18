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
        kit: BarcodeKitDefinition, files: (input: URL, output: URL), errorRate: Double = 0.15, optIn: Bool = false,
        fivePrime: Int = 0, threePrime: Int = 0
    ) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: files.input, barcodeKit: kit, outputDirectory: files.output, barcodeLocation: .bothEnds,
            errorRate: errorRate, maxDistanceFrom5Prime: fivePrime, maxDistanceFrom3Prime: threePrime, engine: .cutadapt,
            keepsUncheckedSamples: optIn
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

    // MARK: - The refusal pass (SAD:106, BIO-DEMUX-THREE item 6, BIO-SATKIT-FLUIDIGM items 1 and 2)

    /// The refusal takes one built-in kit, the Fluidigm Access Array kit, at Both Ends and 5' End, at every error rate.
    /// Cutadapt searches its 864 barcodes anywhere in the read, since no line has a side anchored with `^` or `$`, and BIO
    /// refuses such a kit at every rate (BIO-SATKIT-FLUIDIGM item 1, BIO-SATKIT-ANYWHERE item 1). Its share is pinned at
    /// every rate, so a change to the sum shows up. At 0.10 and 0.15, which each allow 1 error in its 10 bases, the share
    /// alone reaches 0.5. At error 0 the share is 0.4943 as fragments, under 0.5, and its lines with no anchored side refuse
    /// it. The refusal reads only a kit searched as its bare barcodes, the search the floor judges, so a kit searched inside
    /// its flanking adapters is never read, and its long lines with many errors are not worked out here.
    func testTheRefusalTakesOnlyTheFluidigmKitOfTheBuiltInKits() async throws {
        var shares: [String: (single: Double, fragments: Double)] = [:]
        var unbuilt: [String] = []
        var refused: [String] = []
        let input = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        for kit in BarcodeKitRegistry.builtinKits() {
            for errorRate in [0, 0.10, 0.15] {
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
                    let patterns = try pipeline.chancePatterns(in: adapters.adapterFASTA)
                    func share(_ unit: Int) -> Double {
                        DemultiplexChanceFloor.uniformKitShare(
                            patterns: patterns, errorRate: config.effectiveErrorRate, allowsIndels: true, unit: unit
                        )
                    }
                    shares[setting] = (share(1), share(2))
                }
            }
        }
        let saturated = shares.filter { $0.value.fragments >= DemultiplexChanceFloor.saturatedKitShare }.keys.sorted()
        print("SATKIT refusal pass: \(shares.count) bare kit settings, refused \(refused.sorted()), at the share \(saturated), unbuilt \(Set(unbuilt).sorted())")
        XCTAssertGreaterThan(shares.count, 30)
        let fluidigm = ["bothEnds", "fivePrime"].flatMap { location in
            ["0.0", "0.1", "0.15"].map { "fluidigm-access-array \(location) e\($0)" }
        }.sorted()
        XCTAssertEqual(refused.sorted(), fluidigm, "the refusal takes only the Fluidigm kit, at every error rate")
        XCTAssertEqual(saturated, fluidigm.filter { !$0.hasSuffix("e0.0") }, "the share reaches 0.5 at the rates that allow an error")
        for location in ["bothEnds", "fivePrime"] {
            for rate in ["0.1", "0.15"] {
                let share = try XCTUnwrap(shares["fluidigm-access-array \(location) e\(rate)"])
                XCTAssertEqual(share.fragments, 33.569, accuracy: 0.0005, "\(location) e\(rate)")
                XCTAssertEqual(share.single, 16.951, accuracy: 0.0005, "\(location) e\(rate)")
            }
            let exact = try XCTUnwrap(shares["fluidigm-access-array \(location) e0.0"])
            XCTAssertEqual(exact.fragments, 0.4943, accuracy: 0.00005, "\(location) e0")
            XCTAssertEqual(exact.single, 0.2472, accuracy: 0.00005, "\(location) e0")
        }
    }

    /// The setups whose cutadapt lines have no side anchored with `^` or `$`, which preflight refuses at every error rate
    /// (BIO-SATKIT-ANYWHERE items 1 and 2). They are the built-in Fluidigm kit and a definition whose `# kit:` line names it,
    /// which keeps its bare search, the lines `searchesAnywhere` reads to give the Fluidigm words. A custom dual-index
    /// definition at Both Ends with no sample sheet was searched as `i7...i5` with neither side anchored until
    /// BIO-DUAL-ANCHOR, and is now searched as `^i7...i5$`, so it is not such a setup (items 1 to 3). A custom single-index
    /// definition is anchored at every location.
    func testTheSetupsWhoseLinesHaveNoAnchoredSide() async throws {
        let input = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        func assertSearch(
            _ kit: BarcodeKitDefinition, _ location: BarcodeLocation, noAnchoredSide: Bool, bare: Bool
        ) async throws {
            let config = DemultiplexConfig(
                inputURL: input, barcodeKit: kit, outputDirectory: folder, barcodeLocation: location, errorRate: 0,
                engine: .cutadapt
            )
            let work = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let pipeline = DemultiplexingPipeline()
            let adapters = try await pipeline.createAdapterConfiguration(for: config, workDirectory: work)
            let patterns = try pipeline.chancePatterns(in: adapters.adapterFASTA)
            print("SATKIT lines of \(kit.displayName) at \(location): \(Array(patterns.values.joined().prefix(2)))")
            let setting = "\(kit.displayName) at \(location)"
            XCTAssertEqual(DemultiplexChanceFloor.hasNoAnchoredSide(patterns: patterns), noAnchoredSide, setting)
            XCTAssertEqual(DemultiplexChanceFloor.searchesAnywhere(patterns: patterns), bare, setting)
        }
        let fluidigm = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "fluidigm-access-array"))
        try await assertSearch(fluidigm, .bothEnds, noAnchoredSide: true, bare: true)
        let rows = fluidigm.barcodes.prefix(2).map { "\($0.id),\($0.i7Sequence)" }
        let derived = try BarcodeKitRegistry.loadCustomKit(
            text: (["# kit: fluidigm-access-array", "id,sequence"] + rows).joined(separator: "\n") + "\n", name: "Fluidigm Two"
        )
        try await assertSearch(derived, .bothEnds, noAnchoredSide: true, bare: true)
        // The kit `loadCustomKit` makes from rows with an i5 and no `# kit:` line.
        let dual = BarcodeKitDefinition(
            id: "custom-dual-two", displayName: "Dual Two", vendor: "custom", isDualIndexed: true, barcodes: [
                BarcodeEntry(id: "S1", i7Sequence: "ATTACTCG", i5Sequence: "TATAGCCT"),
                BarcodeEntry(id: "S2", i7Sequence: "TCCGGAGA", i5Sequence: "ATAGAGGC"),
            ]
        )
        try await assertSearch(dual, .bothEnds, noAnchoredSide: false, bare: false)
        let single = try Self.definitionKit(Array(Self.qa384Barcodes().prefix(12)), name: "Single Twelve")
        for location in [BarcodeLocation.bothEnds, .fivePrime, .threePrime] {
            try await assertSearch(single, location, noAnchoredSide: false, bare: false)
        }
    }

    // MARK: - The Fluidigm kit (BIO-SATKIT-FLUIDIGM items 1 and 4)

    /// The built-in Fluidigm Access Array kit at the default 0.15 is refused in words that give the cause, that cutadapt
    /// searches its barcodes anywhere in the read, and that name the routes made for it. Its 10-base barcodes are not short.
    func testTheFluidigmKitIsRefusedInWordsThatNameTheRoutesMadeForIt() async throws {
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "fluidigm-access-array"))
        let starts = Array(try Self.fixtureStarts("SRR36291587-R1-first10000-starts12.txt").prefix(200))
        let files = try project(starts: starts)
        var refusal: Error?
        do {
            try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: files))
        } catch {
            refusal = error
        }
        guard case .chanceCheckCannotJudgeKitSearchedAnywhere(let kitName)? = refusal as? DemultiplexError else {
            return XCTFail("the Fluidigm kit was refused as \(String(describing: refusal)), not as a kit searched anywhere")
        }
        XCTAssertEqual(kitName, kit.displayName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path), "a refusal writes nothing")
        let words = try XCTUnwrap(refusal?.localizedDescription)
        for phrase in ["anywhere in the read", "about half of all reads or more", "cannot tell this pool from reads that carry no barcode",
                       "nothing was run", "ONT Fluidigm Sample Split", "--engine header-index", "--keep-unchecked-samples"] {
            XCTAssertTrue(words.contains(phrase), "\(phrase): \(words)")
        }
        XCTAssertFalse(words.contains("short"), words)
        let short = try XCTUnwrap(DemultiplexError.chanceCheckCannotJudgeKit(kitName: "QA 384").errorDescription)
        XCTAssertFalse(short.contains("anywhere"), "a kit of short barcodes keeps its own words")
        try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: files, optIn: true))
    }

    // MARK: - Kits with no anchored side (BIO-SATKIT-ANYWHERE items 1 to 6)

    /// Preflight's refusal of `kit` at `errorRate`, or nil when it passes. The project holds 200 real starts, which the
    /// refusal never reads, and preflight must leave its output folder unmade either way.
    private func refusal(
        _ kit: BarcodeKitDefinition, errorRate: Double, optIn: Bool = false, fivePrime: Int = 0, threePrime: Int = 0
    ) async throws -> DemultiplexError? {
        let files = try project(starts: Array(try Self.fixtureStarts("SRR2584863-R1-first100000-starts12.txt").prefix(200)))
        defer { try? FileManager.default.removeItem(at: files.input.deletingLastPathComponent()) }
        var refusal: DemultiplexError?
        do {
            try await DemultiplexingPipeline().preflight(config: config(
                kit: kit, files: files, errorRate: errorRate, optIn: optIn, fivePrime: fivePrime, threePrime: threePrime
            ))
        } catch let error as DemultiplexError {
            refusal = error
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path), "preflight writes nothing")
        return refusal
    }

    /// 96 pairs of 8 bases from a fixed seed, as BIO-SATKIT-ANYWHERE Q1 measured them: 3 to 5 G or C, and at least 3
    /// differences between any two sequences and between a sequence and the reverse complement of any other.
    static func dualPairs(count: Int = 96) -> [(i7: String, i5: String)] {
        let letters = Array("ACGT")
        var state: UInt64 = 0x5A71_2026_1117_0096
        func reverseComplement(_ bases: [Character]) -> [Character] {
            bases.reversed().map { base in
                switch base {
                case "A": return "T"
                case "C": return "G"
                case "G": return "C"
                default: return "A"
                }
            }
        }
        func distance(_ first: [Character], _ second: [Character]) -> Int { zip(first, second).filter { $0 != $1 }.count }
        var chosen: [[Character]] = []
        while chosen.count < 2 * count {
            let candidate: [Character] = (0..<8).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return letters[Int((state >> 33) & 3)]
            }
            let reverse = reverseComplement(candidate)
            guard (3...5).contains(candidate.filter { $0 == "G" || $0 == "C" }.count), distance(candidate, reverse) >= 3,
                  chosen.allSatisfy({ distance($0, candidate) >= 3 && distance($0, reverse) >= 3 }) else { continue }
            chosen.append(candidate)
        }
        return (0..<count).map { (i7: String(chosen[2 * $0]), i5: String(chosen[2 * $0 + 1])) }
    }

    /// A custom dual-index definition of 96 fixed pairs of 8 bases at Both Ends with no sample sheet, the default location.
    /// Cutadapt searched each pair as `i7...i5` with neither side anchored, so each side was found anywhere in the read, and
    /// 3 bases of a side at a read end also counted. On real reads that carry no such barcodes it placed 8.1% and 11.3% of
    /// the reads at error 0, and 74.0% and 82.2% at 0.15 (BIO-SATKIT-ANYWHERE Q1), so SATKIT-4 refused it at every rate
    /// unless the person kept the unchecked samples. It is now searched as `^i7...i5$` and `^rc(i5)...rc(i7)$`, which placed
    /// 1 read in 54,000 on the same reads, so it runs at every rate with the opt-in and without it (BIO-DUAL-ANCHOR items 1
    /// to 3, Q2). The words of pairs searched anywhere stay for the lines a dual kit with a sample sheet writes (item 8), and
    /// name no Fluidigm route.
    func testACustomDualKitAtBothEndsWithNoSampleSheetRunsAtEveryErrorRate() async throws {
        let kit = try Self.dualKit()
        XCTAssertEqual(kit.barcodes.count, 96)
        XCTAssertEqual(Set(kit.barcodes.compactMap(\.i5Sequence).map(\.count)), [8])
        XCTAssertEqual(kit.pairingMode, .fixedDual)
        XCTAssertNil(kit.sourceKitID)
        for errorRate in [0, 0.15] {
            let error = try await refusal(kit, errorRate: errorRate)
            XCTAssertNil(error, "error \(errorRate) with no opt-in")
        }
        let words = try XCTUnwrap(DemultiplexError.chanceCheckCannotJudgeKitPairsSearchedAnywhere(kitName: "Dual 96").errorDescription)
        for phrase in ["\"Dual 96\"", "anywhere in the read", "A few bases", "nothing was run", "Read Names", "--engine header-index",
                       "Keep Unchecked Samples", "--keep-unchecked-samples"] {
            XCTAssertTrue(words.contains(phrase), "\(phrase): \(words)")
        }
        for phrase in ["Fluidigm", "ont-fluidigm-samples", "sample sheet", "short"] {
            XCTAssertFalse(words.contains(phrase), "\(phrase): \(words)")
        }
        for errorRate in [0, 0.15] {
            let kept = try await refusal(kit, errorRate: errorRate, optIn: true)
            XCTAssertNil(kept, "error \(errorRate) with Keep Unchecked Samples")
        }
    }

    /// A definition whose `# kit:` line names the Fluidigm kit keeps the kit's bare search, its barcodes anywhere in the
    /// read (`BarcodeKitRegistry+DefinitionLayout.swift:55-65`). At error 0 the share of 48 of its barcodes is far under 0.5,
    /// so at the base it passed. It is refused in the Fluidigm words at every rate, and with the opt-in it runs (items 1 and
    /// 6, tests ii and v).
    func testADefinitionBuiltOnTheFluidigmKitIsRefusedAtEveryErrorRate() async throws {
        let fluidigm = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "fluidigm-access-array"))
        let rows = fluidigm.barcodes.prefix(48).map { "\($0.id),\($0.i7Sequence)" }
        let kit = try BarcodeKitRegistry.loadCustomKit(
            text: (["# kit: fluidigm-access-array", "id,sequence"] + rows).joined(separator: "\n") + "\n", name: "Fluidigm Plate"
        )
        XCTAssertEqual(kit.sourceKitID, fluidigm.id)
        for errorRate in [0, 0.15] {
            let error = try await refusal(kit, errorRate: errorRate)
            guard case .chanceCheckCannotJudgeKitSearchedAnywhere(let kitName)? = error else {
                XCTFail("error \(errorRate): the definition was refused as \(String(describing: error)), not as a kit searched anywhere")
                continue
            }
            XCTAssertEqual(kitName, "Fluidigm Plate")
        }
        for errorRate in [0, 0.15] {
            let kept = try await refusal(kit, errorRate: errorRate, optIn: true)
            XCTAssertNil(kept, "error \(errorRate) with Keep Unchecked Samples")
        }
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

    // MARK: - The opt-in of a kit with no anchored side (S3 of SATKIT-4, `requireBarcodesAboveChance`)

    /// The floor of a run that kept the unchecked samples of `kit` at `errorRate`: 1,000 reads, 300 of them on one barcode
    /// and none left over to measure a null from, so a kit that is not saturated keeps the floor of random bases. It is
    /// the floor the run calls.
    private func optedInFloor(_ kit: BarcodeKitDefinition, errorRate: Double) async throws -> (outcome: DemultiplexChanceFloor.Outcome, byShare: Bool, unanchored: Bool) {
        let files = try project(starts: ["ACGTACGTACGT"])
        defer { try? FileManager.default.removeItem(at: files.input.deletingLastPathComponent()) }
        let config = config(kit: kit, files: files, errorRate: errorRate, optIn: true)
        let pipeline = DemultiplexingPipeline()
        let work = folder.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let adapters = try await pipeline.createAdapterConfiguration(for: config, workDirectory: work)
        let patterns = try pipeline.chancePatterns(in: adapters.adapterFASTA)
        let barcode = try XCTUnwrap(patterns.keys.sorted().first)
        let floor = try await pipeline.requireBarcodesAboveChance(
            config: config, adapterFASTA: adapters.adapterFASTA, counts: [barcode: 300], readsSearched: 1_000, unassigned: 700,
            paired: false, unassignedReadsURL: nil
        )
        let outcome = try XCTUnwrap(floor)
        let share = DemultiplexChanceFloor.uniformKitShare(
            patterns: patterns, errorRate: config.effectiveErrorRate, allowsIndels: !config.useNoIndels, unit: 1
        )
        print("SATKIT opt-in floor: \(kit.displayName) at error \(errorRate), null \(outcome.null.rawValue), share \(share)")
        return (outcome, share >= DemultiplexChanceFloor.saturatedKitShare, DemultiplexChanceFloor.hasNoAnchoredSide(patterns: patterns))
    }

    /// A run that keeps the unchecked samples of a kit whose lines have no anchored side says its samples went unchecked,
    /// as a run of a saturated kit does. Preflight refuses these kits at every error rate, so the opt-in is the only way to
    /// run them. At error 0 their share is under 0.5, so their floor stayed the floor of random bases and named a null
    /// that was never measured. The built-in Fluidigm kit and a definition built on it are checked at error 0 and 0.15. A
    /// kit with an anchored side that is under the share keeps its own floor, and so does a custom dual kit at Both Ends with
    /// no sample sheet, whose lines are anchored at both read ends since BIO-DUAL-ANCHOR (items 1 and 4).
    func testTheOptInOfAKitWithNoAnchoredSideNamesTheSaturatedNull() async throws {
        let fluidigm = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "fluidigm-access-array"))
        let plateRows = fluidigm.barcodes.prefix(48).map { "\($0.id),\($0.i7Sequence)" }
        let plate = try BarcodeKitRegistry.loadCustomKit(
            text: (["# kit: fluidigm-access-array", "id,sequence"] + plateRows).joined(separator: "\n") + "\n", name: "Fluidigm Plate"
        )
        for (name, kit) in [("Fluidigm", fluidigm), ("Fluidigm Plate", plate)] {
            for errorRate in [0.0, 0.15] {
                let run = try await optedInFloor(kit, errorRate: errorRate)
                XCTAssertEqual(run.outcome.null, .saturatedKit, "\(name) at error \(errorRate) with Keep Unchecked Samples")
                XCTAssertEqual(run.byShare, errorRate > 0, "\(name) at error \(errorRate): the share reaches 0.5 only when an error is allowed")
                XCTAssertTrue(run.unanchored, "\(name) at error \(errorRate): no side of its lines is anchored")
            }
        }
        let single = try Self.definitionKit(Array(Self.qa384Barcodes().prefix(12)), name: "Single Twelve")
        let anchored = try await optedInFloor(single, errorRate: 0.15)
        XCTAssertEqual(anchored.outcome.null, .randomBases, "a kit with an anchored side, under the share, keeps its own floor")
        XCTAssertFalse(anchored.byShare)
        XCTAssertFalse(anchored.unanchored)
        let dual = try Self.dualKit()
        for errorRate in [0.0, 0.15] {
            let run = try await optedInFloor(dual, errorRate: errorRate)
            XCTAssertEqual(run.outcome.null, .randomBases, "Dual 96 at error \(errorRate) keeps its own floor")
            XCTAssertFalse(run.byShare, "Dual 96 at error \(errorRate)")
            XCTAssertFalse(run.unanchored, "Dual 96 at error \(errorRate): both sides of its lines are anchored")
        }
    }

    // MARK: - A custom dual kit searched at the read ends (BIO-DUAL-ANCHOR items 1 to 5, tests i, iv and v)

    /// `dualPairs(count:)` as a Custom Definition with no `# kit:` line, the kit `loadCustomKit` makes from rows with an i5.
    static func dualKit(count: Int = 96, name: String = "Dual 96") throws -> BarcodeKitDefinition {
        let rows = dualPairs(count: count).enumerated().map { "D\(String(format: "%02d", $0.offset + 1)),\($0.element.i7),\($0.element.i5)" }
        return try BarcodeKitRegistry.loadCustomKit(text: rows.joined(separator: "\n") + "\n", name: name)
    }

    /// The adapter file a run of `kit` at Both Ends with no sample sheet writes, and its lines.
    private func adapterFile(
        _ kit: BarcodeKitDefinition, fivePrime: Int = 0, threePrime: Int = 0
    ) async throws -> (url: URL, lines: [String]) {
        let files = try project(starts: ["ACGTACGTACGT"])
        defer { try? FileManager.default.removeItem(at: files.input.deletingLastPathComponent()) }
        let work = folder.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let config = config(kit: kit, files: files, fivePrime: fivePrime, threePrime: threePrime)
        let adapters = try await DemultiplexingPipeline().createAdapterConfiguration(for: config, workDirectory: work)
        XCTAssertEqual(adapters.adapterFlag, "-g")
        let text = try String(contentsOf: adapters.adapterFASTA, encoding: .utf8)
        return (adapters.adapterFASTA, text.split(separator: "\n").map(String.init))
    }

    /// A custom dual-index definition at Both Ends with no sample sheet is searched as `^i7...i5$` and, for the other strand
    /// of the molecule, `^rc(i5)...rc(i7)$`, so cutadapt needs both barcodes whole at the two ends of the read (BIO-DUAL-ANCHOR
    /// items 1 and 2, test i). At the base the lines were `i7...i5` with no anchor, so each side was found anywhere in the read.
    func testACustomDualKitIsSearchedAsPairsAnchoredAtBothReadEnds() async throws {
        let kit = BarcodeKitDefinition(
            id: "custom-dual-two", displayName: "Dual Two", vendor: "custom", isDualIndexed: true, barcodes: [
                BarcodeEntry(id: "S1", i7Sequence: "ATTACTCG", i5Sequence: "TATAGCCT"),
                BarcodeEntry(id: "S2", i7Sequence: "TCCGGAGA", i5Sequence: "ATAGAGGC"),
            ]
        )
        let lines = try await adapterFile(kit).lines
        XCTAssertEqual(lines, [
            ">S1__lge_forward", "^ATTACTCG...TATAGCCT$",
            ">S1__lge_reverse_complement", "^AGGCTATA...CGAGTAAT$",
            ">S2__lge_forward", "^TCCGGAGA...ATAGAGGC$",
            ">S2__lge_reverse_complement", "^GCCTCTAT...TCTCCGGA$",
        ])
    }

    /// 96 pairs of 8 bases at the default 0.15 with no opt-in pass preflight. Each line is anchored at both read ends, so the
    /// floor can measure a null, and the kit's share is far under 0.5 as single reads and as fragments (BIO-DUAL-ANCHOR item 3,
    /// test iv, Q2). At the base they were refused as pairs searched anywhere.
    func testNinetySixCustomDualPairsAtTheDefaultErrorRateRunWithNoOptIn() async throws {
        let refused = try await refusal(Self.dualKit(), errorRate: 0.15)
        XCTAssertNil(refused, "96 pairs anchored at both read ends, error 0.15, no opt-in")
    }

    /// The floor builds its decoys from the `^` sides of those lines, the i7 and the reverse complement of the i5, so it
    /// measures a null on the run's unassigned reads (BIO-DUAL-ANCHOR item 4, test v). At the base no side was anchored and
    /// `decoyIndex` gave nil.
    func testTheFloorBuildsDecoysForNinetySixAnchoredDualPairs() async throws {
        let file = try await adapterFile(Self.dualKit())
        let patterns = try DemultiplexingPipeline().chancePatterns(in: file.url)
        XCTAssertEqual(patterns.count, 96)
        XCTAssertFalse(DemultiplexChanceFloor.hasNoAnchoredSide(patterns: patterns))
        XCTAssertFalse(DemultiplexChanceFloor.isSaturated(patterns: patterns, errorRate: 0.15, allowsIndels: true, unit: 2))
        XCTAssertNotNil(
            DemultiplexChanceFloor.decoyIndex(patterns: patterns, errorRate: 0.15, allowsIndels: true),
            "the floor measures no null for these lines"
        )
    }

    // MARK: - The line cap (BIO-DUAL-ANCHOR item 5, the refusal pass of SAD)

    /// Each 5' and 3' distance is a line of its own, `(o5 + 1) x (o3 + 1) x 2` a pair, and cutadapt spends a fixed time a run
    /// that grows with the lines, about 29 ms a line, before it reads the first read (BIO-DUAL-ANCHOR Q3). So a setup of more
    /// than 6,000 lines is refused before cutadapt starts, in words that give the cause and both fixes. The refusal pass: 96
    /// pairs at 3/3 (3,072 lines), one pair at 52/47 (5,088, the ONT wrapper of `DemultiplexingPipelineTests`) and one pair
    /// at 59/49 (6,000) pass, and 96 pairs at 5/5 (6,912) and one pair at 59/50 (6,120) are refused.
    func testTheLinesOfACustomDualKitAreCappedAtSixThousand() async throws {
        let ninetySix = try Self.dualKit()
        let one = try Self.dualKit(count: 1, name: "Dual One")
        for (kit, fivePrime, threePrime, lines) in [(ninetySix, 3, 3, 3_072), (one, 52, 47, 5_088), (one, 59, 49, 6_000)] {
            let setting = "\(kit.displayName) at \(fivePrime)/\(threePrime)"
            let written = try await adapterFile(kit, fivePrime: fivePrime, threePrime: threePrime).lines
            XCTAssertEqual(written.count, 2 * lines, setting)
            let refused = try await refusal(kit, errorRate: 0.15, fivePrime: fivePrime, threePrime: threePrime)
            XCTAssertNil(refused, setting)
        }
        for (kit, fivePrime, threePrime, lines) in [(ninetySix, 5, 5, 6_912), (one, 59, 50, 6_120)] {
            let setting = "\(kit.displayName) at \(fivePrime)/\(threePrime)"
            let refused = try await refusal(kit, errorRate: 0.15, fivePrime: fivePrime, threePrime: threePrime)
            guard case .tooManySearchLines(let kitName, let pairs, let o5, let o3, let count)? = refused else {
                XCTFail("\(setting) was refused as \(String(describing: refused)), not for its lines")
                continue
            }
            XCTAssertEqual(kitName, kit.displayName, setting)
            XCTAssertEqual(pairs, kit.barcodes.count, setting)
            XCTAssertEqual([o5, o3], [fivePrime, threePrime], setting)
            XCTAssertEqual(count, lines, setting)
        }
        // A distance of a billion on 96 pairs would overflow Int if multiplied as typed, and is refused like any other.
        let absurd = try await refusal(ninetySix, errorRate: 0.15, fivePrime: 999_999_999, threePrime: 999_999_999)
        guard case .tooManySearchLines(_, let pairs, let o5, let o3, _)? = absurd else {
            return XCTFail("999999999/999999999 was refused as \(String(describing: absurd)), not for its lines")
        }
        XCTAssertEqual([pairs, o5, o3], [96, 999_999_999, 999_999_999])
        let words = try XCTUnwrap(DemultiplexError.tooManySearchLines(
            kitName: "Dual 96", pairs: 96, maxDistanceFrom5Prime: 5, maxDistanceFrom3Prime: 5, lines: 6_912
        ).errorDescription)
        for phrase in ["\"Dual 96\"", "96 barcode pairs", "6,912", "6,000", "nothing was run", "trim", "both distances at 0",
                       "5' Distance", "3' Distance", "--max-distance-5prime", "--max-distance-3prime"] {
            XCTAssertTrue(words.contains(phrase), "\(phrase): \(words)")
        }
        let single = try XCTUnwrap(DemultiplexError.tooManySearchLines(
            kitName: "Dual One", pairs: 1, maxDistanceFrom5Prime: 59, maxDistanceFrom3Prime: 50, lines: 6_120
        ).errorDescription)
        XCTAssertTrue(single.contains("the barcode pair of \"Dual One\""), single)
    }
}
