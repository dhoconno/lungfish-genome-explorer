// DemultiplexVirtualSourceReadsTests.swift - Demultiplexing a virtual bundle reads its reads, never its preview
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A virtual bundle (a subset, trim, orientation map or demultiplexed reads)
// holds only a 1,000-read preview of its own. The exact-bare demultiplex
// engine listed the bundle's files to read, found the preview, and assigned
// the preview's reads instead of the materialized reads the caller resolved,
// both from `lungfish-cli fastq demultiplex <bundle>` and from the dashboard's
// in-process demultiplex. The pipeline now lists only a physical bundle's
// files, so a derived bundle's reads come from the materialized input (R3,
// lane 1x). The cutadapt engine always read the materialized input, and the
// test with it skips when the managed cutadapt is not installed.

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

    private func dashboardRequest(engine: DemultiplexEngine) -> FASTQDerivativeRequest {
        .demultiplex(
            kitID: "custom",
            customCSVPath: kitCSV.path,
            location: "fiveprime",
            symmetryMode: nil,
            maxDistanceFrom5Prime: 0,
            maxDistanceFrom3Prime: 0,
            errorRate: 0.15,
            engine: engine,
            trimBarcodes: false,
            sampleAssignments: nil,
            kitOverride: nil
        )
    }

    /// The demultiplex manifest the dashboard wrote for its first run, in the
    /// `demux` folder inside the source bundle, or beside it.
    private func dashboardManifest() throws -> DemultiplexManifest {
        let folder = virtualSubset.appendingPathComponent(FASTQBundle.demultiplexOutputDirectoryName, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the dashboard writes a demux folder inside the source bundle")
        return try XCTUnwrap(
            DemultiplexManifest.load(from: folder) ?? DemultiplexManifest.load(from: virtualSubset),
            "a demux manifest in \(folder.path) or beside it"
        )
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

    func testTheDashboardExactBareEngineDemultiplexesEveryReadOfAVirtualBundle() async throws {
        try await requireSeqkit()
        _ = try await FASTQDerivativeService.shared.createDerivative(
            from: virtualSubset,
            request: dashboardRequest(engine: .exactBareBarcode)
        )
        assertEveryReadAssigned(try dashboardManifest())
    }

    /// The cutadapt engine always read the materialized input, so its count
    /// is the same before and after the exact-bare fix.
    func testTheDashboardCutadaptEngineStillDemultiplexesEveryReadOfAVirtualBundle() async throws {
        try await requireSeqkit()
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        _ = try await FASTQDerivativeService.shared.createDerivative(
            from: virtualSubset,
            request: dashboardRequest(engine: .cutadapt)
        )
        assertEveryReadAssigned(try dashboardManifest())
    }
}
