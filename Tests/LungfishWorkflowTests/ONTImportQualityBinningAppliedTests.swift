// ONTImportQualityBinningAppliedTests.swift - The ONT import record says whether its binning reached the stored reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Review fix 4 of lane C2-BINNING, adapted by lane C2-ONTBIN. `qualityBinning` keeps the option's value, so the
// replayed flag and the record agree, and `qualityBinningApplied` says whether a stored read received it. Optimize
// Storage bins a flattened payload, a chunked import bins each chunk, and a flattened import without Optimize Storage
// keeps every score. These cases use flattened storage with a stand-in optimizer, so they need no BBTools.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class ONTImportQualityBinningAppliedTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-binning-applied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOptimizeStorageRecordsTheBinningAsApplied() async throws {
        let binned = try await applied(optimizeStorage: true, binning: .illumina4)
        let kept = try await applied(optimizeStorage: true, binning: .none)
        XCTAssertEqual(binned, .boolean(true))
        XCTAssertEqual(kept, .boolean(false))
    }

    func testAFlattenedImportWithoutOptimizeStorageRecordsTheBinningAsNotApplied() async throws {
        let kept = try await applied(optimizeStorage: false, binning: .illumina4)
        XCTAssertEqual(kept, .boolean(false))
    }

    /// BIO-BIN (Phase 3.0 lane BIN, S1). A chunked import that names no binning, the app's and the CLI's default ONT
    /// import, keeps every score. A read the basecaller gave Q0 on every base stays Q0, where `illumina4` stored it as
    /// Q8. It needs no BBTools, since nothing bins.
    func testDefaultChunkedImportKeepsScores() async throws {
        let source = root.appendingPathComponent("run-default/fastq_pass", isDirectory: true)
        let barcode = source.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(to: barcode.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        let output = source.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)

        let result = try await ONTImportWorkflow(optimizationRunner: { _, _, _ in [] }).importDirectory(
            config: ONTImportConfig(sourceDirectory: source, outputDirectory: output, storageMode: .chunked),
            context: ONTImportWorkflow.CommandContext(
                caller: .cli,
                workflowName: "lungfish fastq import-ont",
                workflowVersion: "test",
                toolName: "lungfish fastq import-ont",
                toolVersion: "test",
                argv: ["lungfish-cli", "fastq", "import-ont"],
                reproducibleCommand: "lungfish-cli fastq import-ont",
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:]
            ),
            optimization: ONTImportWorkflow.OptimizationConfig(optimizeStorage: false),
            progress: { _, _ in }
        )
        XCTAssertEqual(result.provenanceEnvelope.options.resolvedDefaults["qualityBinningApplied"], .boolean(false))
        let bundle = try XCTUnwrap(result.importResult.bundleURLs.first)
        let chunks = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: bundle))
        var reads = 0
        for chunk in chunks {
            for try await record in FASTQReader(validateSequence: false).records(from: chunk) {
                reads += 1
                XCTAssertEqual(record.quality.count, 4)
                XCTAssertEqual(record.quality.maxQuality, 0, "a Q0 read is stored as Q0, not raised")
            }
        }
        XCTAssertEqual(reads, 1)
    }

    private func applied(optimizeStorage: Bool, binning: QualityBinningScheme) async throws -> ParameterValue? {
        let source = root.appendingPathComponent("run-\(UUID().uuidString)/fastq_pass", isDirectory: true)
        let barcode = source.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: barcode.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        let output = source.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)

        let workflow = ONTImportWorkflow(optimizationRunner: { _, _, _ in [] })
        let result = try await workflow.importDirectory(
            config: ONTImportConfig(sourceDirectory: source, outputDirectory: output, storageMode: .flattened),
            context: ONTImportWorkflow.CommandContext(
                caller: .cli,
                workflowName: "lungfish fastq import-ont",
                workflowVersion: "test",
                toolName: "lungfish fastq import-ont",
                toolVersion: "test",
                argv: ["lungfish-cli", "fastq", "import-ont"],
                reproducibleCommand: "lungfish-cli fastq import-ont",
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:]
            ),
            optimization: ONTImportWorkflow.OptimizationConfig(optimizeStorage: optimizeStorage, qualityBinning: binning),
            progress: { _, _ in }
        )
        XCTAssertEqual(result.provenanceEnvelope.options.resolvedDefaults["qualityBinning"], .string(binning.rawValue))
        return result.provenanceEnvelope.options.resolvedDefaults["qualityBinningApplied"]
    }
}
