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

    // MARK: - The refusal pass (SAD:106, BIO-DEMUX-THREE item 6, BIO-SATKIT-FLUIDIGM items 1 and 2)

    /// The refusal takes one built-in kit, the Fluidigm Access Array kit, at Both Ends and 5' End, at error rates 0.10 and
    /// 0.15, which each allow 1 error in its 10 bases. Cutadapt searches its 864 barcodes anywhere in the read, and BIO
    /// keeps the refusal for it (BIO-SATKIT-FLUIDIGM item 1). Its share is pinned at every rate, so a change to the sum shows
    /// up. At error 0 the share is 0.4943 as fragments, under 0.5, so the share alone passes it. Item 6 would refuse it there
    /// too, as a kit whose lines have no anchored side, and waits for BIO, since it also takes custom setups
    /// (`testTheSetupsWhoseLinesHaveNoAnchoredSide`). The refusal reads only a kit searched as its bare barcodes, the search
    /// the floor judges, so a kit searched inside its flanking adapters is never read, and its long lines with many errors
    /// are not worked out here.
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
            ["0.1", "0.15"].map { "fluidigm-access-array \(location) e\($0)" }
        }.sorted()
        XCTAssertEqual(refused.sorted(), fluidigm, "the refusal takes only the Fluidigm kit, at the rates that allow an error")
        XCTAssertEqual(saturated, fluidigm)
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

    /// The setups whose cutadapt lines have no side anchored with `^` or `$`, the lines BIO-SATKIT-FLUIDIGM item 6 would
    /// refuse at every error rate. Besides the built-in Fluidigm kit, a definition whose `# kit:` line names it keeps its
    /// bare search, and a custom dual-index definition at Both Ends with no sample sheet is searched as its observed pairs,
    /// `i7...i5`, with neither side anchored. So the rule would take custom setups, and SATKIT-2 stopped it for BIO. A
    /// custom single-index definition is anchored at every location.
    func testTheSetupsWhoseLinesHaveNoAnchoredSide() async throws {
        let input = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        func anchorless(_ kit: BarcodeKitDefinition, _ location: BarcodeLocation) async throws -> Bool {
            let config = DemultiplexConfig(
                inputURL: input, barcodeKit: kit, outputDirectory: folder, barcodeLocation: location, errorRate: 0,
                engine: .cutadapt
            )
            let work = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let pipeline = DemultiplexingPipeline()
            let adapters = try await pipeline.createAdapterConfiguration(for: config, workDirectory: work)
            let lines = try pipeline.chancePatterns(in: adapters.adapterFASTA).values.joined()
            print("SATKIT lines of \(kit.displayName) at \(location): \(Array(lines.prefix(2)))")
            return lines.allSatisfy { line in
                (line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line).components(separatedBy: "...")
                    .allSatisfy { !$0.hasPrefix("^") && !$0.hasSuffix("$") }
            }
        }
        let fluidigm = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "fluidigm-access-array"))
        var anchorlessBothEnds = try await anchorless(fluidigm, .bothEnds)
        XCTAssertTrue(anchorlessBothEnds, "the built-in kit")
        let rows = fluidigm.barcodes.prefix(2).map { "\($0.id),\($0.i7Sequence)" }
        let derived = try BarcodeKitRegistry.loadCustomKit(
            text: (["# kit: fluidigm-access-array", "id,sequence"] + rows).joined(separator: "\n") + "\n", name: "Fluidigm Two"
        )
        anchorlessBothEnds = try await anchorless(derived, .bothEnds)
        XCTAssertTrue(anchorlessBothEnds, "a definition built on the Fluidigm kit")
        // The kit `loadCustomKit` makes from rows with an i5 and no `# kit:` line.
        let dual = BarcodeKitDefinition(
            id: "custom-dual-two", displayName: "Dual Two", vendor: "custom", isDualIndexed: true, barcodes: [
                BarcodeEntry(id: "S1", i7Sequence: "ATTACTCG", i5Sequence: "TATAGCCT"),
                BarcodeEntry(id: "S2", i7Sequence: "TCCGGAGA", i5Sequence: "ATAGAGGC"),
            ]
        )
        anchorlessBothEnds = try await anchorless(dual, .bothEnds)
        XCTAssertTrue(anchorlessBothEnds, "a custom dual-index definition at Both Ends with no sample sheet")
        let single = try Self.definitionKit(Array(Self.qa384Barcodes().prefix(12)), name: "Single Twelve")
        for location in [BarcodeLocation.bothEnds, .fivePrime, .threePrime] {
            let anchorlessSingle = try await anchorless(single, location)
            XCTAssertFalse(anchorlessSingle, "\(location)")
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
        for phrase in ["anywhere in the read", "nearly every read", "cannot tell this pool from reads that carry no barcode",
                       "nothing was run", "ONT Fluidigm Sample Split", "--engine header-index", "--keep-unchecked-samples"] {
            XCTAssertTrue(words.contains(phrase), "\(phrase): \(words)")
        }
        XCTAssertFalse(words.contains("short"), words)
        let short = try XCTUnwrap(DemultiplexError.chanceCheckCannotJudgeKit(kitName: "QA 384").errorDescription)
        XCTAssertFalse(short.contains("anywhere"), "a kit of short barcodes keeps its own words")
        try await DemultiplexingPipeline().preflight(config: config(kit: kit, files: files, optIn: true))
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
