// DemultiplexMultiFileRootReadsTests.swift - Demultiplexing a multi-file root counts the reads its barcode bundles hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A bundle that holds several files (an ONT chunked import or a virtual
// merge) is demultiplexed as every file it holds, and each barcode bundle
// lists every file's reads (lane 1x). The cutadapt engine's virtual mode
// rebuilt each barcode's statistics and preview from one root file, the
// first chunk, so the demultiplex manifest's input, per-barcode and
// unassigned counts and every child's cached statistics counted the first
// chunk only. In this fixture that was 3 of the 7 reads. Both now stream
// every root file through `FASTQBundle.rootSequenceURLs`, in manifest
// order, the resolution the materializer uses (R3, final review B1). The
// exact-bare engine counts through its own accumulators and was right
// before the change. A single-file root is unchanged, and
// DemultiplexVirtualSourceReadsTests covers it.
//
// Every case runs the managed seqkit, and the cutadapt cases the managed
// cutadapt, so they skip when those are not installed.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class DemultiplexMultiFileRootReadsTests: XCTestCase {
    private var root: URL!
    private var multiFile: URL!
    private var kitCSV: URL!

    private static let barcode = "ACGTTGCAAGTC"
    private static let insert = "GATTACAGATTACAGATTACAGATTACA"
    /// Three reads in the first chunk and four in the second, every one carrying BC01.
    private static let firstChunkIDs = ["c0r1", "c0r2", "c0r3"]
    private static let secondChunkIDs = ["c1r1", "c1r2", "c1r3", "c1r4"]
    private static var allIDs: [String] { firstChunkIDs + secondChunkIDs }

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-multi-file-root")
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        multiFile = imports.appendingPathComponent("multi.lungfishfastq", isDirectory: true)
        let chunks = multiFile.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try FASTQOperationTestHelper.writeFASTQ(
            records: Self.firstChunkIDs.map { (id: $0, sequence: Self.barcode + Self.insert) },
            to: chunks.appendingPathComponent("run_0.fastq")
        )
        try FASTQOperationTestHelper.writeFASTQ(
            records: Self.secondChunkIDs.map { (id: $0, sequence: Self.barcode + Self.insert) },
            to: chunks.appendingPathComponent("run_1.fastq")
        )
        try FASTQOperationTestHelper.writeFASTQ(
            records: [(id: Self.firstChunkIDs[0], sequence: Self.barcode + Self.insert)],
            to: multiFile.appendingPathComponent("preview.fastq")
        )
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: multiFile)

        kitCSV = root.appendingPathComponent("barcodes.csv")
        try "id,sequence\nBC01,\(Self.barcode)\n".write(to: kitCSV, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTools(cutadapt: Bool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
        if cutadapt {
            guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
                try ToolAvailability.skipOrFail("managed cutadapt is not installed")
            }
        }
    }

    /// A virtual subset of every read of the multi-file root, recording the
    /// root's first chunk as its root file, as the dashboard recorded it.
    private func writeVirtualSubset() throws -> URL {
        let subset = multiFile.deletingLastPathComponent()
            .appendingPathComponent("multi-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: subset, withIntermediateDirectories: true)
        try (Self.allIDs.joined(separator: "\n") + "\n")
            .write(to: subset.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try FASTQOperationTestHelper.writeFASTQ(
            records: [(id: Self.firstChunkIDs[0], sequence: Self.barcode + Self.insert)],
            to: subset.appendingPathComponent("preview.fastq")
        )
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "c")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "multi-subset",
                parentBundleRelativePath: "@/Imports/multi.lungfishfastq",
                rootBundleRelativePath: "@/Imports/multi.lungfishfastq",
                rootFASTQFilename: "chunks/run_0.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: Self.allIDs.count, baseCount: Int64(Self.allIDs.count * 40)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: subset
        )
        return subset
    }

    /// Checks that the demultiplex manifest and the BC01 bundle describe the
    /// reads the bundle holds and materializes to, every chunk's reads.
    private func assertCountsMatchTheReads(
        manifest: DemultiplexManifest,
        outputDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let bc01 = try XCTUnwrap(manifest.barcodes.first { $0.barcodeID == "BC01" }, file: file, line: line)
        let child = outputDirectory.appendingPathComponent(bc01.bundleRelativePath, isDirectory: true)
        let derived = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: child), file: file, line: line)
        let readIDs = try String(contentsOf: child.appendingPathComponent("read-ids.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let materializedURL = root.appendingPathComponent("materialized-\(UUID().uuidString).fastq")
        try await FASTQDerivativeService.shared.exportMaterializedFASTQ(fromDerivedBundle: child, to: materializedURL)
        let materialized = try await FASTQOperationTestHelper.loadFASTQRecords(from: materializedURL)
        let materializedBases = materialized.reduce(Int64(0)) { $0 + Int64($1.length) }
        let previewIDs = try await FASTQOperationTestHelper.loadFASTQRecords(
            from: child.appendingPathComponent("preview.fastq")
        ).map(\.identifier)

        XCTAssertEqual(Set(readIDs), Set(Self.allIDs), "read-ids.txt lists every chunk's reads", file: file, line: line)
        XCTAssertEqual(materialized.count, Self.allIDs.count, "the child materializes every chunk's reads", file: file, line: line)
        XCTAssertEqual(manifest.inputReadCount, Self.allIDs.count, "the manifest's input count covers every chunk", file: file, line: line)
        XCTAssertEqual(bc01.readCount, Self.allIDs.count, "the manifest counts the reads the barcode bundle holds", file: file, line: line)
        XCTAssertEqual(bc01.baseCount, materializedBases, "the manifest's bases are the bases the bundle materializes to", file: file, line: line)
        XCTAssertEqual(manifest.unassigned.readCount, 0, file: file, line: line)
        XCTAssertEqual(derived.cachedStatistics.readCount, Self.allIDs.count, "the child's cached statistics count the reads it holds", file: file, line: line)
        XCTAssertEqual(derived.cachedStatistics.baseCount, materializedBases, file: file, line: line)
        XCTAssertEqual(Set(previewIDs), Set(Self.allIDs), "the preview holds reads of every chunk", file: file, line: line)
    }

    /// `lungfish-cli fastq demultiplex <multi-file bundle>` with `engine`, the
    /// command the FASTQ operations dialog runs.
    private func runCLIDemultiplex(engine: String) async throws {
        let output = root.appendingPathComponent("Project.lungfish/Analyses/cli-demux-\(engine)", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([
            multiFile.path, "--kit", kitCSV.path, "--output", output.path, "--engine", engine,
            "--location", "5prime", "--no-trim",
        ]).run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "a demux manifest in \(output.path)")

        // A physical multi-file bundle gives physical barcode bundles, which
        // hold the reads of every chunk themselves.
        let bc01 = try XCTUnwrap(manifest.barcodes.first { $0.barcodeID == "BC01" })
        let child = output.appendingPathComponent(bc01.bundleRelativePath, isDirectory: true)
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: child), "the reads of \(child.lastPathComponent)")
        let childReads = try await FASTQOperationTestHelper.loadFASTQRecords(from: payload)
        XCTAssertEqual(Set(childReads.map(\.identifier)), Set(Self.allIDs), "the barcode bundle holds every chunk's reads")
        XCTAssertEqual(manifest.inputReadCount, Self.allIDs.count, "the manifest's input count covers every chunk")
        XCTAssertEqual(bc01.readCount, Self.allIDs.count, "the manifest counts the reads the barcode bundle holds")
        XCTAssertEqual(bc01.baseCount, childReads.reduce(Int64(0)) { $0 + Int64($1.length) })
        XCTAssertEqual(manifest.unassigned.readCount, 0)
    }

    func testTheCLICutadaptEngineCountsTheReadsOfEveryFileOfAMultiFileBundle() async throws {
        try await requireTools(cutadapt: true)
        try await runCLIDemultiplex(engine: "cutadapt")
    }

    func testTheCLIExactBareEngineStillCountsTheReadsOfEveryFileOfAMultiFileBundle() async throws {
        try await requireTools(cutadapt: false)
        try await runCLIDemultiplex(engine: "exact-bare")
    }

    /// `lungfish-cli fastq demultiplex <virtual subset over the multi-file
    /// root>` runs the cutadapt engine's virtual mode with the subset's root.
    func testTheCLICutadaptEngineCountsTheReadsOfEveryFileUnderAVirtualSubset() async throws {
        try await requireTools(cutadapt: true)
        let subset = try writeVirtualSubset()
        let output = root.appendingPathComponent("Project.lungfish/Analyses/cli-demux", isDirectory: true)
        try await FastqDemultiplexSubcommand.parse([
            subset.path, "--kit", kitCSV.path, "--output", output.path, "--location", "5prime", "--no-trim",
        ]).run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        let bc01 = try XCTUnwrap(manifest.barcodes.first { $0.barcodeID == "BC01" })
        let child = output.appendingPathComponent(bc01.bundleRelativePath, isDirectory: true)
        guard case .demuxedVirtual = FASTQBundle.loadDerivedManifest(in: child)?.payload else {
            return XCTFail("the CLI writes virtual barcode bundles over the subset's root")
        }
        try await assertCountsMatchTheReads(manifest: manifest, outputDirectory: output)
    }
}
