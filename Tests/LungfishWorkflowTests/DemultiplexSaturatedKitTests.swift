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
}
