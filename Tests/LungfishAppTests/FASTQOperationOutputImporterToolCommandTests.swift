// FASTQOperationOutputImporterToolCommandTests.swift - Derivative provenance names the lungfish-cli invocation that ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog runs each derivative as `lungfish-cli fastq
// <subcommand>`, and FASTQOperationOutputImporter records a command in the
// derived bundle's manifest (`operation.toolCommand`, which the Inspector shows
// with a Copy button). It used to record a second encoding with the CLI's own
// output file as the input, and for five kinds a native tool that never ran,
// such as `seqkit seq --reverse --complement` for a reverse complement (R3, R8).
// These tests import operation outputs and check that the manifest records the
// invocation FASTQOperationCLIInvocationBuilder builds for the same request,
// the one the dialog row records and the execution service runs.

import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQOperationOutputImporterToolCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input
        // resolvers hand the CLI, so the paths the tests compare agree.
        let made = try TestTempDirectory.make(prefix: "fastq-importer-tool-command")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    /// `words` with the value after `-o` replaced by `value`.
    private func replacingOutput(in words: [String], with value: String) throws -> [String] {
        let index = try XCTUnwrap(words.firstIndex(of: "-o"), "no -o in \(words)")
        var replaced = words
        replaced[index + 1] = value
        return replaced
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A physical source bundle in a project's Imports folder with four reads.
    private func makeSourceBundle(named name: String = "Sample 1") throws -> (bundleURL: URL, fastqURL: URL) {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: imports)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 4, readLength: 20)
        return bundle
    }

    private func makeWriter() -> AppFASTQOutputBundleWriter {
        AppFASTQOutputBundleWriter(
            ingestor: CopyingFASTQOutputIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
    }

    /// The Operations panel command for a dialog launch, as
    /// `MainSplitViewController.beginFASTQLaunchRequestOperation` records it.
    private func dialogRowCommand(for request: FASTQOperationLaunchRequest) throws -> String {
        FASTQOperationCLIInvocationBuilder.commandLine(
            for: try FASTQOperationExecutionService().buildInvocation(for: request)
        )
    }

    func testImportedDerivativeRecordsTheReverseComplementInvocationThatRanNotSeqkit() async throws {
        let source = try makeSourceBundle()
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = FASTQOperationExecutionService(
            commandRunner: InProcessLungfishCLIRunner(),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destination, fastqBundleWriter: makeWriter())
        )

        let result = try await service.execute(
            request: .derivative(request: .reverseComplement, inputURLs: [source.bundleURL], outputMode: .perInput),
            workingDirectory: root.appendingPathComponent("work", isDirectory: true)
        )

        let bundleURL = try XCTUnwrap(result.importedURLs.first)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        let toolCommand = try XCTUnwrap(manifest.operation.toolCommand)
        let finalPayload = bundleURL.appendingPathComponent(manifest.rootFASTQFilename)

        // The words that ran, with the file the CLI read replaced by the
        // bundle the request names and its scratch output by the final payload.
        let ran = try XCTUnwrap(result.executedInvocations.first)
        XCTAssertEqual(ran.subcommand, "fastq")
        XCTAssertEqual(ran.arguments.count, 4)
        XCTAssertEqual(ran.arguments.first, "reverse-complement")
        XCTAssertEqual(ran.arguments[1], source.fastqURL.path)
        XCTAssertEqual(ran.arguments[2], "-o")
        XCTAssertEqual(
            try AdvancedCommandLineOptions.parse(toolCommand),
            [CLICommandIdentity.executableName, "fastq", "reverse-complement", source.bundleURL.path, "-o", finalPayload.path]
        )
        let command = try RecordedCLICommand.parse(toolCommand, as: FastqReverseComplementSubcommand.self)
        XCTAssertEqual(command.input, source.bundleURL.path)
        XCTAssertEqual(command.output.output, finalPayload.path)
        XCTAssertFalse(toolCommand.contains("seqkit"), toolCommand)
        XCTAssertFalse(toolCommand.contains(ran.arguments[3]), "the CLI's scratch output is not the input")
        XCTAssertEqual(manifest.lineage.last?.toolCommand, toolCommand)
        XCTAssertEqual(manifest.operation.toolUsed, CLICommandIdentity.executableName)
    }

    func testImportedDerivativesRecordTheDialogRowCommandWithTheFinalOutput() async throws {
        let source = try makeSourceBundle()
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let primers = FASTQPrimerTrimConfiguration(
            source: .reference, mode: .linked, referenceFasta: root.appendingPathComponent("primers.fasta").path,
            errorRate: 0.08, minimumOverlap: 9, tool: .cutadapt
        )
        // The first five kinds used to record cutadapt, seqkit, vsearch and
        // deacon commands, and the primer trim left out its cutadapt-linked engine.
        let requests: [FASTQDerivativeRequest] = [
            .sequencePresenceFilter(
                sequence: "ACGT", fastaPath: nil, searchEnd: .fivePrime, minOverlap: 4,
                errorRate: 0.1, keepMatched: true, searchReverseComplement: false
            ),
            .reverseComplement,
            .orient(
                referenceURL: root.appendingPathComponent("ref.fasta"),
                wordLength: 12, dbMask: "dust", saveUnoriented: false, extraArguments: []
            ),
            .humanReadScrub(databaseID: DeaconPanhumanDatabaseInstaller.databaseID, removeReads: true),
            .primerRemoval(configuration: primers),
            .subsampleCount(2),
            .lengthFilter(min: 10, max: 40),
        ]

        for (index, request) in requests.enumerated() {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: request, inputURLs: [source.bundleURL], outputMode: .perInput
            )
            let staging = root.appendingPathComponent("work-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = staging.appendingPathComponent("\(request.operationKindString).fastq")
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: staged, readCount: 2, readLength: 20)
            try SyntheticToolProvenance.write(
                argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
                inputURL: source.fastqURL,
                outputURL: staged,
                in: staging
            )

            let bundleURL = try await makeWriter().importFASTQOutput(
                sourceURL: staged,
                bundleURL: destination.appendingPathComponent(
                    "Sample 1-\(request.operationKindString).\(FASTQBundle.directoryExtension)"
                ),
                originalRequest: launch,
                sourceInputURL: source.bundleURL
            )

            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL), request.operationLabel)
            let finalPayload = bundleURL.appendingPathComponent(manifest.rootFASTQFilename)
            let recorded = try RecordedCLICommand.arguments(of: manifest.operation.toolCommand)
            let row = try RecordedCLICommand.arguments(of: try dialogRowCommand(for: launch))
            XCTAssertEqual(
                recorded,
                try replacingOutput(in: row, with: finalPayload.path),
                "\(request.operationLabel): the dialog row and the provenance differ only in the output"
            )
            XCTAssertNoThrow(try RecordedCLICommand.parse(manifest.operation.toolCommand), request.operationLabel)
            XCTAssertFalse(recorded.contains(staged.path), "\(request.operationLabel): the CLI's output is not the input")
        }
    }

    func testRibosomalRNAOutputRecordsTheFolderOfThePublishedBundlesAsTheOutputDirectory() async throws {
        let source = try makeSourceBundle(named: "source")
        let staging = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedFASTQ = staging.appendingPathComponent("source.norrna.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedFASTQ, readCount: 2, readLength: 20)
        try SyntheticToolProvenance.write(
            argv: ["deacon", "filter", source.fastqURL.path, "-o", stagedFASTQ.path],
            inputURL: source.fastqURL,
            outputURL: stagedFASTQ,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let bundleURL = try await makeWriter().importFASTQOutput(
            sourceURL: stagedFASTQ,
            bundleURL: destination.appendingPathComponent("source-deacon-ribo-norrna.\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: .ribosomalRNAFilter(retention: .both, ensure: .none),
                inputURLs: [source.bundleURL],
                outputMode: .perInput
            ),
            sourceInputURL: source.bundleURL
        )

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        XCTAssertEqual(manifest.operation.riboDetectorRetention, .nonRRNA)
        let command = try RecordedCLICommand.parse(manifest.operation.toolCommand, as: FastqDeaconRiboSubcommand.self)
        XCTAssertEqual(command.inputs, [source.bundleURL.path])
        XCTAssertEqual(command.retain, FASTQRiboDetectorRetention.both.rawValue, "the run kept both classes")
        XCTAssertEqual(command.databaseID, DeaconRibokmersDatabaseInstaller.databaseID)
        XCTAssertEqual(
            URL(fileURLWithPath: command.outputDirectory).standardizedFileURL,
            destination.standardizedFileURL,
            "`fastq deacon-ribo -o` takes a folder, the one that holds the published bundles"
        )
    }
}

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary would parse it.
private struct InProcessLungfishCLIRunner: FASTQOperationCommandRunning {
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

/// A one-step provenance envelope beside a staged output, as a CLI run writes it.
private enum SyntheticToolProvenance {
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
