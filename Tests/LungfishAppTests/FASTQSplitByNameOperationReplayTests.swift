// FASTQSplitByNameOperationReplayTests.swift - The dialog's pair-aware runs and their recorded commands agree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// fastq deduplicate and fastq primer-remove split a file that mixes mate
// pairs with single reads by name, and run a strictly interleaved file in
// their tool's paired mode (lane A8). Each test runs the Operations dialog
// path on a fixture bundle (the execution service with the real subcommand
// in process and the real importer), takes the command the dialog records,
// replays it through the real CLI on the same bundle, and checks that both
// hold the same pairs and single reads, every pair whole. The managed tools
// run, so the class sits in the integration tier by its name.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQSplitByNameOperationReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "split-by-name-replay")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTool(_ tool: NativeTool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("managed \(tool.rawValue) is not installed")
        }
    }

    /// The mate sequences of each pair and the sequence of each single read
    /// of a file, sorted so two runs compare whatever order their tool wrote.
    private struct Fragments: Equatable {
        var pairs: [[String]]
        var singles: [String]
    }

    private func fragments(_ url: URL) async throws -> Fragments {
        let records = try await InterleavedFASTQFixture.readRecords(at: url)
        var pairs: [[String]] = []
        var singles: [String] = []
        var index = 0
        while index < records.count {
            if index + 1 < records.count,
               InterleavedFASTQFixture.fragmentKey(records[index]) == InterleavedFASTQFixture.fragmentKey(records[index + 1]) {
                pairs.append([records[index].sequence, records[index + 1].sequence])
                index += 2
            } else {
                singles.append(records[index].sequence)
                index += 1
            }
        }
        return Fragments(pairs: pairs.sorted { $0.joined() < $1.joined() }, singles: singles.sorted())
    }

    /// Runs the dialog path and returns the imported derivative's reads and
    /// the command the dialog row records.
    private func dialogRun(
        _ request: FASTQDerivativeRequest,
        on bundle: URL,
        label: String
    ) async throws -> (payload: URL, recordedCommand: String) {
        let destination = root.appendingPathComponent("Derived-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = FASTQOperationExecutionService(
            commandRunner: InProcessFASTQCommandRunner(),
            directImporter: BundleFASTQOperationImporter(
                destinationDirectory: destination,
                fastqBundleWriter: AppFASTQOutputBundleWriter(
                    ingestor: CopyingFASTQOutputIngestor(),
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
        return (payload, recorded)
    }

    /// Runs the recorded command through the real CLI with `<derived>`
    /// replaced by an output path.
    private func replay(_ recordedCommand: String, label: String) async throws -> URL {
        let outputURL = root.appendingPathComponent("replay-\(label).fastq")
        let words = try RecordedCLICommand.arguments(of: recordedCommand).map { $0 == "<derived>" ? outputURL.path : $0 }
        let command = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var runnable = command as? AsyncParsableCommand else {
            XCTFail("\(label): \(type(of: command)) is not runnable")
            return outputURL
        }
        try await runnable.run()
        return outputURL
    }

    // MARK: - Deduplicate

    func testDeduplicateOfAMixedBundleReplaysToTheSamePairsAndSingleReads() async throws {
        try await requireTool(.clumpify)
        // Pair 6 repeats pair 1 and merged read 3 repeats merged read 0.
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "mixed-dedup", in: root, pairCount: 8, mergedCount: 4, naming: .identical,
            sequences: { InterleavedFASTQFixture.defaultSequences($0 == 6 ? 1 : $0) },
            mergedSequences: { InterleavedFASTQFixture.defaultMergedSequence($0 == 3 ? 0 : $0) }
        )
        let request = FASTQDerivativeRequest.deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40)
        let dialog = try await dialogRun(request, on: bundle.bundleURL, label: "dedup")
        let parsed = try RecordedCLICommand.parse(dialog.recordedCommand, as: FastqDeduplicateSubcommand.self)
        XCTAssertEqual(parsed.pairing.pairing, .interleaved, dialog.recordedCommand)
        XCTAssertEqual(parsed.input, bundle.bundleURL.path)

        let dialogReads = try await fragments(dialog.payload)
        XCTAssertEqual(dialogReads.pairs.count, 7, "one copy of the repeated pair, every pair whole")
        XCTAssertEqual(dialogReads.singles.count, 3, "one copy of the repeated merged read")
        let replayed = try await fragments(try await replay(dialog.recordedCommand, label: "dedup"))
        XCTAssertEqual(replayed, dialogReads, "the recorded command reproduces the dialog's reads")
    }
}

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary would parse it.
private struct InProcessFASTQCommandRunner: FASTQOperationCommandRunning {
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

/// Stands in for the re-ingestion and copies the operation's output into
/// the staging bundle unchanged, so the replay compares the CLI's own output.
private struct CopyingFASTQOutputIngestor: FASTQOutputIngesting {
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
