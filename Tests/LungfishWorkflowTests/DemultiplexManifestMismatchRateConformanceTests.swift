// DemultiplexManifestMismatchRateConformanceTests.swift - What the manifest records as maxMismatches, against the rate cutadapt ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane PROBES-A, row DEMUX-MANIFEST-MISMATCH-RATE, flipped by lane FIX-IDT on BIO's word (BIO-PROBES-A,
// Q1 item 3). The manifest's `parameters.maxMismatches` is a record fact, so it is `Int(config.effectiveErrorRate x
// first barcode length)` (`DemultiplexingPipeline.swift`, the `DemultiplexParameters` call), the rate cutadapt and the
// chance floor run at. It was `config.errorRate`, the configured rate. The two differ only when a run carries a
// source platform other than the kit's and the configured rate is below that platform's recommended rate (0.15 for
// ONT, 0.10 for every other platform), so the default 0.15 records what it always did. No route in the product sets a
// source platform on a run: `lungfish-cli fastq demultiplex` has no such option, and the Demux tab's Detect uses its
// platform only for scouting. Nothing reads the field, so it reaches the manifest file and no screen, export or
// record text.
//
// A real-tool suite. Its name puts it in the conformance tier, and it skips when managed cutadapt or seqkit is
// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexManifestMismatchRateConformanceTests: XCTestCase {
    private var root: URL!
    private static let kit = BarcodeKitRegistry.truseqSingleA

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-manifest-mismatch-rate")
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

    /// 60 reads of D701, 30 of D702 and 60 with no barcode, each barcode followed by the same pseudo-random insert bases.
    private func writeReads() throws -> (project: URL, input: URL) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var state: UInt64 = 7
        func insert() -> String {
            String((0..<90).map { _ -> Character in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Array("ACGT")[Int((state >> 33) % 4)]
            })
        }
        let barcodes = Array(repeating: "ATTACTCG", count: 60) + Array(repeating: "TCCGGAGA", count: 30) + Array(repeating: "", count: 60)
        let text = barcodes.enumerated().map { index, barcode -> String in
            let bases = barcode + insert()
            return "@r\(index)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
        }.joined()
        let input = project.appendingPathComponent("reads.fastq")
        try text.write(to: input, atomically: true, encoding: .utf8)
        return (project, input)
    }

    private func run(errorRate: Double, sourcePlatform: LungfishIO.SequencingPlatform?) async throws
        -> (maxMismatches: Int, cutadaptRate: Double) {
        let (project, input) = try writeReads()
        let config = DemultiplexConfig(
            inputURL: input,
            barcodeKit: Self.kit,
            outputDirectory: project.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: .fivePrime,
            errorRate: errorRate,
            threads: 1,
            engine: .cutadapt,
            sourcePlatform: sourcePlatform
        )
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        let parameters = result.manifest.parameters
        let words = (parameters.commandLine ?? "").split(separator: " ").map(String.init)
        let rate = try XCTUnwrap(words.firstIndex(of: "-e").flatMap { Double(words[$0 + 1]) }, "the recorded command names -e")
        return (parameters.maxMismatches, rate)
    }

    func testARunWithoutASourcePlatformRecordsTheMismatchesItsRateAllowed() async throws {
        try await requireTools()
        let ran = try await run(errorRate: 0.15, sourcePlatform: nil)
        XCTAssertEqual(ran.cutadaptRate, 0.15, accuracy: 1e-9)
        XCTAssertEqual(ran.maxMismatches, Int(ran.cutadaptRate * Double(Self.kit.barcodes[0].i7Sequence.count)))
        XCTAssertEqual(ran.maxMismatches, 1, "0.15 of 8 bases allows one mismatch")
    }

    /// The reach is a run the product cannot make. At 0.05 with an ONT source on an Illumina kit, cutadapt runs at 0.15
    /// (one mismatch of eight) and the manifest records 1, the mismatches cutadapt allowed, and not 0 from the configured 0.05.
    func testACrossPlatformConfigRunsTheEffectiveRateAndTheManifestRecordsIt() async throws {
        try await requireTools()
        XCTAssertEqual(LungfishIO.SequencingPlatform.oxfordNanopore.recommendedErrorRate, 0.15, accuracy: 1e-9)
        let ran = try await run(errorRate: 0.05, sourcePlatform: .oxfordNanopore)
        XCTAssertEqual(ran.cutadaptRate, 0.15, accuracy: 1e-9, "cutadapt ran at the effective rate")
        XCTAssertEqual(ran.maxMismatches, 1, "the manifest records what cutadapt allowed at its effective rate (DEMUX-MANIFEST-MISMATCH-RATE)")
    }
}
