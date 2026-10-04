// FASTQDialogRowFixtures.swift - Fixtures the dialog row command tests share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow

/// Stands in for the re-ingestion (clumpify and compression) and copies the
/// operation's output into the staging bundle unchanged.
struct DialogRowCopyingIngestor: FASTQOutputIngesting {
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

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary would parse it.
struct DialogRowInProcessCLIRunner: FASTQOperationCommandRunning {
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

/// A one-step provenance envelope beside a staged output, as a CLI run writes it.
enum DialogRowStagedProvenance {
    static func write(argv: [String], inputURL: URL, outputURL: URL, in directory: URL) throws {
        let startedAt = Date(timeIntervalSince1970: 1_800)
        let endedAt = Date(timeIntervalSince1970: 1_801)
        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: outputURL, format: .fastq, role: .output)
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq fixture",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "fixture-tool",
            toolVersion: "1.0.0"
        )
        .argv(argv)
        .options(explicit: [:], defaults: [:], resolved: [:])
        .input(inputURL, format: .fastq, role: .input)
        .output(outputURL, format: .fastq, role: .output)
        .step(ProvenanceStep(
            toolName: "fixture-tool",
            toolVersion: "1.0.0",
            argv: argv,
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 1,
            startedAt: startedAt,
            completedAt: endedAt
        ))
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: endedAt)
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
    }
}
