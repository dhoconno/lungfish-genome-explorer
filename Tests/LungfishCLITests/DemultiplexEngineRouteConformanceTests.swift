// DemultiplexEngineRouteConformanceTests.swift - `fastq demultiplex` with and without --engine on header-index reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L4). `--engine` had the default `cutadapt`, so every run searched the read bases, and
// the recorded command left the engine out. A run with no --engine asks the route owner, and an explicit
// `--engine cutadapt` keeps today's search of the bases and is recorded, so a recorded command replays as it ran.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// A real-tool suite: it skips when managed cutadapt or seqkit is missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class DemultiplexEngineRouteConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-engine-route")
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

    /// 80 reads led by D701, 80 by D702 and 40 bare, every name carrying D701 in its Casava comment.
    private func writeInput() throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("named-and-led.fastq")
        let bases: [Character] = ["A", "C", "G", "T"]
        var state: UInt64 = 3
        var text = ""
        for index in 0..<200 {
            let lead = index < 80 ? "ATTACTCG" : (index < 160 ? "TCCGGAGA" : "")
            var sequence = lead
            while sequence.count < 150 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                sequence.append(bases[Int((state >> 33) % 4)])
            }
            // Two samples' indexes, since one sample's names take the bases search (BIO-DEMUX-FLOOR item 1).
            let nameIndex = index.isMultiple(of: 2) ? "ATTACTCG" : "TCCGGAGA"
            text += "@r\(index) 1:N:0:\(nameIndex)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        try text.write(to: input, atomically: true, encoding: .utf8)
        return input
    }

    func testExplicitCutadaptEngineKeepsTheInlineSearch() async throws {
        try await requireTools()
        let input = try writeInput()
        let output = root.appendingPathComponent("Project.lungfish/Analyses/explicit", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([
            input.path, "--kit", "truseq-single-a", "--output", output.path, "--engine", "cutadapt", "--location", "5prime",
        ]).run()

        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        let counts = Dictionary(uniqueKeysWithValues: manifest.barcodes.map { ($0.barcodeID, $0.readCount) })
        XCTAssertGreaterThanOrEqual(counts["D701"] ?? 0, 70)
        XCTAssertGreaterThanOrEqual(counts["D702"] ?? 0, 70)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        let engineIndex = try XCTUnwrap(provenance.argv.firstIndex(of: "--engine"), "the recorded command names the engine: \(provenance.argv)")
        XCTAssertEqual(provenance.argv[engineIndex + 1], "cutadapt")
        XCTAssertEqual(provenance.options.explicit["engine"], .string("cutadapt"))
        XCTAssertEqual(provenance.options.explicit["indexSource"], .string("read-sequences"))
    }

    /// 200 reads led by D701, 3 by D702 and 2,000 of random bases, no name carrying an index, so the run searches
    /// the bases and D702 sits within chance.
    private func writeChanceInput() throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("chance.fastq")
        let bases: [Character] = ["A", "C", "G", "T"]
        var state: UInt64 = 17
        var text = ""
        for index in 0..<2_203 {
            var sequence = index < 200 ? "ATTACTCG" : (index < 203 ? "TCCGGAGA" : "")
            while sequence.count < 150 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                sequence.append(bases[Int((state >> 33) % 4)])
            }
            text += "@c\(index)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }
        try text.write(to: input, atomically: true, encoding: .utf8)
        return input
    }

    /// DEMUXFLOOR-ARCH SF1: the record keys of BIO's chance floor (BIO-DEMUX-FLOOR item 10) are pinned by name.
    func testRunRecordNamesTheChanceFloorTrialsAndTheBarcodesWithinChance() async throws {
        try await requireTools()
        let input = try writeChanceInput()
        let output = root.appendingPathComponent("Project.lungfish/Analyses/chance", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([input.path, "--kit", "truseq-single-a", "--output", output.path]).run()

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        guard case .dictionary(let floor)? = provenance.options.explicit["chanceFloor"] else {
            return XCTFail("the record has no chanceFloor dictionary: \(provenance.options.explicit)")
        }
        XCTAssertEqual(floor["kitTail"], .number(1e-6))
        guard case .integer(let trials)? = floor["chanceTrials"] else { return XCTFail("no chanceTrials: \(floor)") }
        XCTAssertGreaterThan(trials, 0)
        // BIO-DEMUX-NULL item 9: what the chance count was measured on, its margin and the windows it was tallied from.
        guard case .string(let null)? = floor["null"] else { return XCTFail("no null: \(floor)") }
        XCTAssertTrue(["start-composition", "random-bases"].contains(null), "the null is named by its two words: \(null)")
        guard case .number(let margin)? = floor["margin"] else { return XCTFail("no margin: \(floor)") }
        XCTAssertGreaterThanOrEqual(margin, 1)
        guard case .integer(let compositionReads)? = floor["compositionReads"] else {
            return XCTFail("no compositionReads: \(floor)")
        }
        XCTAssertGreaterThanOrEqual(compositionReads, 0)
        guard case .dictionary(let within)? = floor["barcodesWithinChance"] else { return XCTFail("no barcodesWithinChance: \(floor)") }
        guard case .integer(let d702)? = within["D702"] else { return XCTFail("D702 is not named within chance: \(within)") }
        XCTAssertGreaterThanOrEqual(d702, 3)
        XCTAssertNil(within["D701"], "a barcode of 200 reads is not within chance")

        // Exact Bare Barcode takes no floor, so its record has no chanceFloor key.
        let sheet = root.appendingPathComponent("Project.lungfish/sheet.csv")
        try "S1,ATTACTCG\nS2,TCCGGAGA\n".write(to: sheet, atomically: true, encoding: .utf8)
        let exact = root.appendingPathComponent("Project.lungfish/Analyses/exact", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([
            input.path, "--kit", sheet.path, "--output", exact.path, "--engine", "exact-bare",
        ]).run()
        XCTAssertNil(try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: exact)).options.explicit["chanceFloor"])
    }

    /// DEMUXFLOOR-ARCH SF3: a run with no engine records the engine the route owner chose (L4's record clause).
    func testRunWithNoEngineRecordsCutadaptInItsCommandAndParameters() async throws {
        try await requireTools()
        let input = try writeChanceInput()
        let output = root.appendingPathComponent("Project.lungfish/Analyses/no-engine", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([input.path, "--kit", "truseq-single-a", "--output", output.path]).run()
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        let engineIndex = try XCTUnwrap(provenance.argv.firstIndex(of: "--engine"), "\(provenance.argv)")
        XCTAssertEqual(provenance.argv[engineIndex + 1], "cutadapt")
        XCTAssertEqual(provenance.options.explicit["engine"], .string("cutadapt"))
        XCTAssertEqual(provenance.options.explicit["indexSource"], .string("read-sequences"))
    }

    func testDemultiplexWithNoEngineOnNamesCarryingTheKitsIndexRefusesBeforeAnyTool() async throws {
        try await requireTools()
        let input = try writeInput()
        let output = root.appendingPathComponent("Project.lungfish/Analyses/routed", isDirectory: true)
        do {
            try await FastqDemultiplexSubcommand.parse([
                input.path, "--kit", "truseq-single-a", "--output", output.path, "--location", "5prime",
            ]).run()
            XCTFail("a run with no --engine on names that carry the kit's index searched the read bases")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("These reads carry their index in the read names"),
                error.localizedDescription
            )
        }
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(items, [], "no output is published")
        // The staging folder and the provenance sidecar start with a dot, so the filter above cannot see them.
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [])
            .filter { $0.hasPrefix(".lungfish-demux-incomplete-") || $0.hasSuffix("lungfish-provenance.json") }
        XCTAssertEqual(leftovers, [], "a refused run leaves no staging folder and no record")
        XCTAssertNil(try ProvenanceEnvelopeReader.loadCanonical(from: output))
    }
}
