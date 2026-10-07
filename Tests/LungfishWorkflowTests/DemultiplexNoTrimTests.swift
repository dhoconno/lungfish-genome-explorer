// DemultiplexNoTrimTests.swift - A demultiplex run that keeps barcodes keeps every read whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `fastq demultiplex --no-trim` (Trim Barcodes off in the dialog) runs cutadapt
// with `--action none`. In virtual mode the pipeline still read cutadapt's
// info file, which records every match whatever the action, and wrote the
// matches as the bundle's trims, so the barcode bundles materialized
// shorter reads than were demultiplexed (Phase 1 lane 1z, L5 item 2). The
// both-end pass of a long-read kit trimmed the 5' construct whatever the
// setting, so physical ONT bundles lost it under --no-trim too.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexNoTrimTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-no-trim")
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

    private func fastq(_ reads: [(name: String, sequence: String)]) -> String {
        reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
    }

    private func reads(_ url: URL) async throws -> [(name: String, sequence: String)] {
        var reads: [(String, String)] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            reads.append((record.identifier, record.sequence))
        }
        return reads
    }

    func testAVirtualRunThatKeepsBarcodesMaterializesTheReadsItDemultiplexed() async throws {
        try await requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let rootBundle = project.appendingPathComponent("Imports/raw.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let barcoded = [
            (name: "r1", sequence: "ACGTTGCA" + "GATTACAGATTACAGATTACAGATTACA"),
            (name: "r2", sequence: "ACGTTGCA" + "TTGGCCAATTGGCCAATTGGCCAATTGG"),
        ]
        let readsURL = rootBundle.appendingPathComponent("reads.fastq")
        try fastq(barcoded + [(name: "r3", sequence: "CCCCCCCC" + "GATTACAGATTACAGATTACAGATTACA")])
            .write(to: readsURL, atomically: true, encoding: .utf8)
        let kitCSV = root.appendingPathComponent("kit.csv")
        try "id,sequence\nBC01,ACGTTGCA\n".write(to: kitCSV, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: readsURL,
                sourceBundleURL: rootBundle,
                barcodeKit: try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "kit"),
                outputDirectory: output,
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 8,
                trimBarcodes: false,
                threads: 1,
                rootBundleURL: rootBundle,
                rootFASTQFilename: "reads.fastq",
                inputSequenceFormat: .fastq
            ),
            progress: { _, _ in }
        )

        let bundle = try XCTUnwrap(result.outputBundleURLs.first)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent(FASTQBundle.trimPositionFilename).path),
            "a run that keeps barcodes writes no barcode trims"
        )
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        XCTAssertEqual(manifest.cachedStatistics.readCount, 2)
        XCTAssertEqual(manifest.cachedStatistics.minReadLength, 36, "the cached lengths are the demultiplexed lengths")
        XCTAssertEqual(manifest.cachedStatistics.maxReadLength, 36)
        let materialized = try await FASTQCLIMaterializer(runner: .shared).materialize(
            bundleURL: bundle,
            tempDirectory: root.appendingPathComponent("materialized", isDirectory: true),
            progress: { _ in }
        )
        let materializedReads = try await reads(materialized)
        XCTAssertEqual(materializedReads.map(\.name), barcoded.map(\.name))
        XCTAssertEqual(materializedReads.map(\.sequence), barcoded.map(\.sequence), "the barcode stays in each read")
    }

    func testALongReadBothEndRunThatKeepsBarcodesKeepsTheFivePrimeConstruct() async throws {
        try await requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let kit = BarcodeKitRegistry.ontNativeBarcoding24
        let barcode = try XCTUnwrap(kit.barcodes.first(where: { $0.id == "barcode13" }))
        let context = ONTNativeAdapterContext()
        let insert = String(repeating: "GATTACA", count: 20)
        let read = context.fivePrimeSpec(barcodeSequence: barcode.i7Sequence) + insert
            + context.threePrimeSpec(barcodeSequence: barcode.i7Sequence)
        let input = project.appendingPathComponent("input.fastq")
        try fastq([(name: "read_0", sequence: read)]).write(to: input, atomically: true, encoding: .utf8)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: input,
                barcodeKit: kit,
                outputDirectory: project.appendingPathComponent("demux-out", isDirectory: true),
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 20,
                trimBarcodes: false,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), ["barcode13"])
        let bundle = try XCTUnwrap(result.outputBundleURLs.first)
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let output = try await reads(payload)
        XCTAssertEqual(output.map(\.sequence.count), [read.count], "the read keeps both constructs")
        XCTAssertEqual(result.manifest.barcodes.first?.baseCount, Int64(read.count))
    }
}
