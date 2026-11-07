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
            text += "@r\(index) 1:N:0:ATTACTCG\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
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
    }
}
