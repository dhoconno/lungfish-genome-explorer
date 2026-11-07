// DemultiplexChanceFloorOutputModeConformanceTests.swift - The chance floor measures its own null in every output mode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXNULL-3, blocker B1 of review DEMUXNULL-SWIFT. The floor tallied the start composition from the
// unassigned bundle's first FASTQ. In virtual mode (a derived input) that bundle holds a 1,000-read preview, and a run that
// discards its unassigned reads removed the bundle before the floor ran, so the floor measured on a preview or kept to
// random bases, the floor that passed chance matches as samples on 61 of 87 real cuts. It now tallies the unassigned
// reads cutadapt wrote, in every output mode.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// A real-tool suite. Its name puts it in the conformance tier, and it skips when managed cutadapt or seqkit is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class DemultiplexChanceFloorOutputModeConformanceTests: XCTestCase {
    private var root: URL!
    private static let barcode = "GTATCGTCGT"
    private static let kit = BarcodeKitDefinition(
        id: "custom-fluidigm-subset",
        displayName: "Custom Fluidigm Subset",
        vendor: "custom",
        isDualIndexed: false,
        pairingMode: .singleEnd,
        barcodes: [BarcodeEntry(id: "FLD0001", i7Sequence: barcode)]
    )

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-floor-output-mode")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private enum Mode: String, CaseIterable {
        case materialized, virtual, discard
    }

    /// 1,500 random 40-base reads and 40 reads that start with the kit's barcode, run materialized, virtual (the input is
    /// a derived dataset of its root) and with the unassigned reads discarded. In each the floor measures the start
    /// composition of every unassigned read, not of a preview, and a discarded unassigned bundle is gone afterwards.
    func testChanceFloorMeasuresItsOwnNullInEveryOutputMode() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt),
              await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed cutadapt or seqkit is not installed")
            return
        }
        let reads = 1_540
        var missed: [String] = []
        for mode in Mode.allCases {
            let workspace = root.appendingPathComponent("\(mode.rawValue).lungfish/workspace", isDirectory: true)
            let bundleURL = workspace.appendingPathComponent("input.\(FASTQBundle.directoryExtension)", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
            try DemuxFloorFixtures.write(
                names: (0..<reads).map { "r\($0)" }, leads: Array(repeating: Self.barcode, count: 40),
                seed: 35, length: 40, to: fastqURL
            )
            let outputDir = workspace.appendingPathComponent("demux-out", isDirectory: true)
            let result = try await DemultiplexingPipeline().run(
                config: DemultiplexConfig(
                    inputURL: bundleURL,
                    barcodeKit: Self.kit,
                    outputDirectory: outputDir,
                    barcodeLocation: .fivePrime,
                    errorRate: 0.0,
                    minimumOverlap: 10,
                    trimBarcodes: true,
                    unassignedDisposition: mode == .discard ? .discard : .keep,
                    threads: 1,
                    rootBundleURL: mode == .virtual ? bundleURL : nil,
                    rootFASTQFilename: mode == .virtual ? fastqURL.lastPathComponent : nil
                ),
                progress: { _, _ in }
            )

            let assigned = result.manifest.barcodes.reduce(0) { $0 + $1.readCount }
            XCTAssertGreaterThanOrEqual(assigned, 40, "\(mode): the barcode reads were not assigned")
            let floor = try XCTUnwrap(result.chanceFloor, "\(mode): the floor did not run")
            if floor.null != .startComposition || floor.compositionReads != reads - assigned {
                missed.append("\(mode): \(floor.null.rawValue) on \(floor.compositionReads) starts of \(reads - assigned)")
            }
            if mode == .discard {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
                XCTAssertFalse(left.contains { $0.hasPrefix("unassigned") }, "the discarded unassigned bundle stayed: \(left)")
            }
        }
        // At the base: virtual start-composition on 1000 starts of 1500, discard random-bases on 0 starts of 1500.
        XCTAssertEqual(missed, [], "the floor did not measure every unassigned read")
    }
}
