// FASTQIngestionTrimGaloreMixedTests.swift - Trim Galore stores merged reads and pairs as clumpify stores them (CHTC lane C2-TRIMGALORE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A merging recipe ends with one file of merged reads followed by each R1 beside its R2. The bbtools storage step
// scans the mates by name, clumps the pairs and the unpaired reads apart and joins them. Trim Galore ran one paired or
// one single-end call and failed on such a file after the whole recipe had run (2026-10-20, owner direction O7).

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

final class FASTQIngestionTrimGaloreMixedTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimGaloreMixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Skips, or under `LUNGFISH_REQUIRE_TOOLS=1` fails, unless the managed Trim Galore, the BBTools scripts the two
    /// routes use and a compressor are installed.
    private func requireTools() async throws {
        let runner = NativeToolRunner.shared
        for tool in [NativeTool.trimGalore, .clumpify, .reformat] {
            guard (try? await runner.toolPath(for: tool)) != nil else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
            }
        }
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    private func store(
        _ input: URL, with tool: ClumpingTool, in root: URL, label: String
    ) async throws -> (result: FASTQIngestionResult, directory: URL) {
        let directory = root.appendingPathComponent("\(label)-out", isDirectory: true)
        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [input],
                pairingMode: .interleaved,
                outputDirectory: directory,
                threads: 2,
                deleteOriginals: false,
                clumpingTool: tool
            ),
            progress: { _, _ in }
        )
        return (result, directory)
    }

    func testTrimGaloreStoresMergedReadsAndPairsAsClumpifyStoresThem() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 8, merged: 6)

        let clumpify = try await store(input, with: .bbtools, in: root, label: "bbtools")
        let trimGalore = try await store(input, with: .trimGalore, in: root, label: "trim-galore")

        let reference = try MixedStorageFASTQ.layout(of: clumpify.result.outputFile)
        let stored = try MixedStorageFASTQ.layout(of: trimGalore.result.outputFile)
        XCTAssertEqual(reference.pairs, 8, "the bbtools route is the reference layout")
        XCTAssertEqual(reference.unpaired, 6)
        XCTAssertTrue(reference.pairsBeforeUnpaired)
        XCTAssertEqual(stored.pairs, 8, "every pair stays with its mate")
        XCTAssertEqual(stored.unpaired, 6, "every merged read is kept")
        XCTAssertTrue(stored.pairsBeforeUnpaired, "pairs are stored interleaved ahead of the unpaired reads, as clumpify stores them")
        XCTAssertEqual(stored.names, reference.names, "the same reads are stored")
        XCTAssertEqual(
            try FASTQPairInterleaver.countRecords(in: trimGalore.result.outputFile),
            try FASTQPairInterleaver.countRecords(in: clumpify.result.outputFile)
        )
        XCTAssertTrue(trimGalore.result.wasClumpified)
        XCTAssertEqual(trimGalore.result.resolvedClumpingTool, .trimGalore)
        // Each half goes once it is processed and the scratch folder goes with the run.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: trimGalore.directory.path),
            [trimGalore.result.outputFile.lastPathComponent]
        )
    }

    func testEachTrimGaloreCallIsOneProvenanceStepWithItsArgv() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 5, merged: 4)

        let trimGalore = try await store(input, with: .trimGalore, in: root, label: "trim-galore")

        let calls = trimGalore.result.provenanceSteps.filter { $0.toolName == "trim_galore" }
        XCTAssertEqual(calls.count, 2, "one step for the pairs call and one for the unpaired call")
        let pairsCall = try XCTUnwrap(calls.first)
        let unpairedCall = try XCTUnwrap(calls.last)
        XCTAssertTrue(pairsCall.command.contains("--paired"))
        XCTAssertEqual(pairsCall.inputs.count, 2, "the pairs call read R1 and R2")
        XCTAssertFalse(unpairedCall.command.contains("--paired"))
        XCTAssertEqual(unpairedCall.inputs.count, 1)
        for call in calls {
            XCTAssertTrue(call.command.contains("--clumpify"))
            XCTAssertEqual(call.exitCode, 0)
        }
        let commandLine = try XCTUnwrap(trimGalore.result.processingCommandLine)
        XCTAssertEqual(commandLine.components(separatedBy: "trim_galore ").count - 1, 2, commandLine)
    }

    /// Trim Galore removes reads shorter than its length cutoff, which the import sheet tells the user. Such a read
    /// is not lost data, so the stored file may hold fewer reads than the scan found and never more.
    func testAReadTrimGaloreFiltersOutIsNotMistakenForLoss() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 6, merged: 5, shortMerged: 1)

        let trimGalore = try await store(input, with: .trimGalore, in: root, label: "trim-galore")

        let stored = try MixedStorageFASTQ.layout(of: trimGalore.result.outputFile)
        XCTAssertEqual(stored.pairs, 6)
        XCTAssertEqual(stored.unpaired, 5, "only the 12-base merged read is filtered out")
        XCTAssertFalse(stored.names.contains("short1"))
        XCTAssertTrue(stored.pairsBeforeUnpaired)
    }
}
