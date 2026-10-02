// FASTQOperationReplayParityTests.swift - The command the dialog records replays to the dialog's reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog runs each derivative as `lungfish-cli fastq
// <subcommand>` on the file it resolves for the bundle, and records
// `lungfish-cli fastq <subcommand> <bundle>` in the Operations panel and
// the derivative's provenance. The subcommands used to refuse a bundle
// path, so no recorded FASTQ command replayed. Each test here runs the
// dialog path on a fixture bundle, takes the command it recorded, runs that
// command through the real CLI on the same bundle, and shows both outputs
// hold the same reads, for a physical single-file bundle, a multi-file
// bundle, a fullPaired bundle and a virtual subset (R3, lane 1x).
//
// The reverse complement is pure Swift. The length filter runs seqkit, the
// fixed trim runs fastp and the fullPaired bundle needs reformat.sh, so
// those cases skip when the managed tools are missing.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQOperationReplayParityTests: XCTestCase {
    private var root: URL!
    private var shapes: AssemblyBundleShapes!
    /// A virtual subset of `shapes.single` holding s1 and s3.
    private var virtualSubset: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-operation-replay")
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        shapes = try AssemblyBundleShapes(in: project)
        virtualSubset = project.appendingPathComponent("Imports/single-subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: virtualSubset, withIntermediateDirectories: true)
        try "s1\ns3\n".write(to: virtualSubset.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try AssemblyBundleShapes.fastq(["s1"]).write(to: virtualSubset.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "s")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "single-subset",
                parentBundleRelativePath: "@/Imports/single.lungfishfastq",
                rootBundleRelativePath: "@/Imports/single.lungfishfastq",
                rootFASTQFilename: "single.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: virtualSubset
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTool(_ tool: NativeTool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("managed \(tool.rawValue) is not installed")
        }
    }

    private func records(_ url: URL) async throws -> [(id: String, sequence: String)] {
        try await FASTQOperationTestHelper.loadFASTQRecords(from: url).map { ($0.identifier, $0.sequence) }
    }

    /// Runs the dialog path (the execution service with the real subcommand
    /// in process and the real importer) and returns the imported
    /// derivative's reads and the command the dialog row recorded.
    private func dialogRun(
        _ request: FASTQDerivativeRequest,
        on bundle: URL,
        label: String
    ) async throws -> (reads: [(id: String, sequence: String)], recordedCommand: String) {
        let destination = root.appendingPathComponent("Derived-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = FASTQOperationExecutionService(
            commandRunner: InProcessCLIRunner(),
            directImporter: BundleFASTQOperationImporter(
                destinationDirectory: destination,
                fastqBundleWriter: AppFASTQOutputBundleWriter(
                    ingestor: CopyingOutputIngestor(),
                    statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
                )
            )
        )
        let launch = FASTQOperationLaunchRequest.derivative(request: request, inputURLs: [bundle], outputMode: .perInput)
        let recorded = FASTQOperationCLIInvocationBuilder.commandLine(for: try service.buildInvocation(for: launch))
        let result = try await service.execute(
            request: launch,
            workingDirectory: root.appendingPathComponent("work-\(label)", isDirectory: true)
        )
        let imported = try XCTUnwrap(result.importedURLs.first, "\(label): one derivative was imported")
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: imported), "\(label): the derivative holds its reads")
        return (try await records(payload), recorded)
    }

    /// Runs the recorded command through the real CLI with `<derived>`
    /// replaced by an output path, and returns that output's reads.
    private func replay(_ recordedCommand: String, label: String) async throws -> [(id: String, sequence: String)] {
        let outputURL = root.appendingPathComponent("replay-\(label).fastq")
        let words = try RecordedCLICommand.arguments(of: recordedCommand).map { $0 == "<derived>" ? outputURL.path : $0 }
        let command = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var runnable = command as? AsyncParsableCommand else {
            XCTFail("\(label): \(type(of: command)) is not runnable")
            return []
        }
        try await runnable.run()
        return try await records(outputURL)
    }

    private func assertReplayMatches(
        _ request: FASTQDerivativeRequest,
        on bundle: URL,
        label: String,
        expectedIDs: [String]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let dialog = try await dialogRun(request, on: bundle, label: label)
        XCTAssertTrue(dialog.recordedCommand.contains(bundle.path), "\(label): the recorded command names the bundle", file: file, line: line)
        let replayed = try await replay(dialog.recordedCommand, label: label)
        XCTAssertEqual(replayed.map(\.id), dialog.reads.map(\.id), "\(label): the same reads", file: file, line: line)
        XCTAssertEqual(replayed.map(\.sequence), dialog.reads.map(\.sequence), "\(label): the same sequences", file: file, line: line)
        if let expectedIDs {
            XCTAssertEqual(dialog.reads.map(\.id), expectedIDs, "\(label): the reads the dialog produced", file: file, line: line)
        }
    }

    // MARK: - Reverse complement (a full payload, pure Swift)

    func testReverseComplementReplaysForEveryBundleShape() async throws {
        try await assertReplayMatches(.reverseComplement, on: shapes.single, label: "rc-single", expectedIDs: ["s1", "s2", "s3"])
        try await assertReplayMatches(.reverseComplement, on: shapes.multiFile, label: "rc-multi", expectedIDs: ["m1", "m2", "m3", "m4", "m5"])
        try await assertReplayMatches(.reverseComplement, on: virtualSubset, label: "rc-virtual", expectedIDs: ["s1", "s3"])
    }

    func testReverseComplementReplaysForAFullPairedBundle() async throws {
        try await requireTool(.reformat)
        try await assertReplayMatches(.reverseComplement, on: shapes.paired, label: "rc-paired", expectedIDs: ["p1/1", "p1/2", "p2/1", "p2/2"])
    }

    // MARK: - Length filter (a subset, seqkit)

    func testLengthFilterReplaysForEveryBundleShape() async throws {
        try await requireTool(.seqkit)
        let request = FASTQDerivativeRequest.lengthFilter(min: 5, max: 20)
        try await assertReplayMatches(request, on: shapes.single, label: "lf-single", expectedIDs: ["s1", "s2", "s3"])
        try await assertReplayMatches(request, on: shapes.multiFile, label: "lf-multi", expectedIDs: ["m1", "m2", "m3", "m4", "m5"])
        try await assertReplayMatches(request, on: virtualSubset, label: "lf-virtual", expectedIDs: ["s1", "s3"])
    }

    func testLengthFilterReplaysForAFullPairedBundle() async throws {
        try await requireTool(.seqkit)
        try await requireTool(.reformat)
        try await assertReplayMatches(.lengthFilter(min: 5, max: 20), on: shapes.paired, label: "lf-paired", expectedIDs: ["p1/1", "p1/2", "p2/1", "p2/2"])
    }

    // MARK: - Fixed trim (a trim, fastp)

    func testFixedTrimReplaysForEveryBundleShape() async throws {
        try await requireTool(.fastp)
        let request = FASTQDerivativeRequest.fixedTrim(from5Prime: 2, from3Prime: 0)
        try await assertReplayMatches(request, on: shapes.single, label: "trim-single")
        try await assertReplayMatches(request, on: shapes.multiFile, label: "trim-multi", expectedIDs: ["m1", "m2", "m3", "m4", "m5"])
        try await assertReplayMatches(request, on: virtualSubset, label: "trim-virtual", expectedIDs: ["s1", "s3"])
    }

    func testFixedTrimReplaysForAFullPairedBundle() async throws {
        try await requireTool(.fastp)
        try await requireTool(.reformat)
        try await assertReplayMatches(.fixedTrim(from5Prime: 2, from3Prime: 0), on: shapes.paired, label: "trim-paired")
    }
}

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary would parse it.
private struct InProcessCLIRunner: FASTQOperationCommandRunning {
    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        let words = invocation.subcommand.split(separator: " ").map(String.init) + invocation.arguments
        let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var command = parsed as? AsyncParsableCommand else {
            throw CocoaError(.featureUnsupported)
        }
        try await command.run()
        return FASTQCLIExecutionResult(outputURLs: [])
    }
}

/// Stands in for the re-ingestion (clumpify and compression) and copies the
/// operation's output into the staging bundle unchanged.
private struct CopyingOutputIngestor: FASTQOutputIngesting {
    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {
        let input = config.inputFiles[0]
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let output = config.outputDirectory.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: output)
        return FASTQIngestionResult(
            outputFile: output,
            wasClumpified: false,
            qualityBinning: config.qualityBinning,
            originalFilenames: [input.lastPathComponent],
            originalSizeBytes: 0,
            finalSizeBytes: 0,
            pairingMode: config.pairingMode
        )
    }
}
