// DemultiplexVirtualSourceReadsTests.swift - Demultiplexing a virtual bundle reads its reads, never its preview
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A virtual bundle (a subset, trim, orientation map or demultiplexed reads)
// holds only a 1,000-read preview of its own. The exact-bare demultiplex
// engine listed the bundle's files to read, found the preview, and assigned
// the preview's reads instead of the materialized reads the caller resolved,
// from `lungfish-cli fastq demultiplex <bundle>`. The pipeline now lists only a
// physical bundle's files, so a derived bundle's reads come from the
// materialized input (R3, lane 1x). The cutadapt engine always read the
// materialized input, and the test with it skips when the managed cutadapt is
// not installed.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class DemultiplexVirtualSourceReadsTests: XCTestCase {
    private var root: URL!
    private var rootBundle: URL!
    private var virtualSubset: URL!
    private var kitCSV: URL!

    /// More reads than a preview holds, every one carrying barcode BC01.
    private static let readCount = 1_200
    private static let previewReadCount = 1_000
    private static let barcode = "ACGTTGCAAGTC"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-virtual-source")
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        rootBundle = imports.appendingPathComponent("root.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let reads = (1...Self.readCount).map { index in
            (id: "r\(index)", sequence: Self.barcode + "GATTACAGATTACAGATTACA")
        }
        try FASTQOperationTestHelper.writeFASTQ(records: reads, to: rootBundle.appendingPathComponent("root.fastq"))

        virtualSubset = imports.appendingPathComponent("subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: virtualSubset, withIntermediateDirectories: true)
        try reads.map(\.id).joined(separator: "\n").appending("\n")
            .write(to: virtualSubset.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try FASTQOperationTestHelper.writeFASTQ(
            records: Array(reads.prefix(Self.previewReadCount)),
            to: virtualSubset.appendingPathComponent("preview.fastq")
        )
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "r")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "subset",
                parentBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootFASTQFilename: "root.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: Self.readCount, baseCount: Int64(Self.readCount * 33)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: virtualSubset
        )

        kitCSV = root.appendingPathComponent("barcodes.csv")
        try "id,sequence\nBC01,\(Self.barcode)\n".write(to: kitCSV, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireSeqkit() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed (the subset is materialized with it)")
        }
    }

    private func assertEveryReadAssigned(_ manifest: DemultiplexManifest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(manifest.inputReadCount, Self.readCount, "every materialized read, not the \(Self.previewReadCount) of the preview", file: file, line: line)
        XCTAssertEqual(manifest.barcodes.first { $0.barcodeID == "BC01" }?.readCount, Self.readCount, file: file, line: line)
        XCTAssertEqual(manifest.unassigned.readCount, 0, file: file, line: line)
    }

    func testTheCLIExactBareEngineDemultiplexesEveryReadOfAVirtualBundle() async throws {
        try await requireSeqkit()
        let output = root.appendingPathComponent("cli-demux", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([
            virtualSubset.path, "--kit", kitCSV.path, "--output", output.path, "--engine", "exact-bare", "--location", "5prime",
        ]).run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        assertEveryReadAssigned(manifest)
    }

    /// The cutadapt engine always read the materialized input, so its count
    /// is the same before and after the exact-bare fix.
    func testTheCLICutadaptEngineStillDemultiplexesEveryReadOfAVirtualBundle() async throws {
        try await requireSeqkit()
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        // The cutadapt engine joins its reads beside its output, which must sit in a project.
        let output = root.appendingPathComponent("Project.lungfish/Analyses/cli-demux-cutadapt", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([
            virtualSubset.path, "--kit", kitCSV.path, "--output", output.path, "--engine", "cutadapt",
            "--location", "5prime", "--no-trim",
        ]).run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        assertEveryReadAssigned(manifest)
    }
}
