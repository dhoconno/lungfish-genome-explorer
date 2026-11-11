// FASTQOperationRowCommandTests.swift - The dialog row names the real output after its run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog registers its Operations row before the run,
// when no output exists, so a derivative row shows `-o <derived>` and a
// Savont row shows `--output <derived>`. docs/contracts/CLI-EQUIVALENCE.md
// lets the row replace that command with `setCommand` once the output paths are
// known. These tests import real outputs through the importer and apply
// `FASTQOperationRowCommand`, and check that the row then holds the command the
// manifest records, or the executed Savont command, parsed with the real CLI
// parser. A row that cannot be refined without making it worse keeps its
// `begin` command and logs why.

import ArgumentParser
import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQOperationRowCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input
        // resolvers hand the CLI, so the paths the tests compare agree.
        let made = try TestTempDirectory.make(prefix: "fastq-row-command")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixtures

    /// A physical source bundle in a project's Imports folder with four reads.
    private func makeSourceBundle(named name: String) throws -> (bundleURL: URL, fastqURL: URL) {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: imports)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 4, readLength: 20)
        return bundle
    }

    private func makeWriter() -> AppFASTQOutputBundleWriter {
        AppFASTQOutputBundleWriter(
            ingestor: DialogRowCopyingIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
    }

    /// Imports one staged output of `request` on `source` as a derived bundle, as the dialog's
    /// importer does for each of its outputs, and returns the bundle.
    private func importOutput(
        of request: FASTQDerivativeRequest,
        on source: (bundleURL: URL, fastqURL: URL),
        named name: String
    ) async throws -> URL {
        let staging = root.appendingPathComponent("work-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(name).fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: staged, readCount: 2, readLength: 20)
        try DialogRowStagedProvenance.write(
            argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
            inputURL: source.fastqURL,
            outputURL: staged,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: destination.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(request: request, inputURLs: [source.bundleURL], outputMode: .perInput),
            sourceInputURL: source.bundleURL
        )
    }

    private func derivativeLaunch(
        _ request: FASTQDerivativeRequest,
        on sources: [(bundleURL: URL, fastqURL: URL)]
    ) -> FASTQOperationLaunchRequest {
        .derivative(request: request, inputURLs: sources.map(\.bundleURL), outputMode: .perInput)
    }

    /// Registers the dialog row for `launch` on `reporter`, as the launch site does. `outputTargetPath` is the output
    /// the launch site spells in the command, `<derived>` unless the output is known before `begin`.
    private func beginRow(
        for launch: FASTQOperationLaunchRequest,
        on reporter: RecordingOperationReporter,
        outputTargetPath: String = "<derived>"
    ) throws -> UUID {
        try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(launch.operationDisplayTitle)",
            request: launch,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            outputTargetPath: outputTargetPath,
            reporter: reporter
        ) { _ in }.requireStarted()
    }

    private func payload(of bundleURL: URL) throws -> URL {
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        return bundleURL.appendingPathComponent(manifest.rootFASTQFilename)
    }

    // MARK: - Derivatives

    func testAOneInputDerivativeRowNamesTheImportedPayloadAfterTheRun() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let request = FASTQDerivativeRequest.lengthFilter(min: 10, max: 40)
        let bundleURL = try await importOutput(of: request, on: source, named: "Sample 1-length")
        let launch = derivativeLaunch(request, on: [source])
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [bundleURL], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertTrue(begun.contains("<derived>"), "the row records the placeholder at begin: \(begun)")

        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)

        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        XCTAssertEqual(row, manifest.operation.toolCommand, "the row holds the command the manifest records")
        XCTAssertFalse(row.contains("<derived>"), row)
        let finalPayload = try payload(of: bundleURL)
        let commands = try RecordedCLICommand.parseScript(row)
        XCTAssertEqual(commands.count, 1)
        let lengthFilter = try XCTUnwrap(commands.first as? FastqLengthFilterSubcommand)
        XCTAssertEqual(lengthFilter.input, source.bundleURL.path)
        XCTAssertEqual(lengthFilter.output.output, finalPayload.path, "the command writes the imported payload")
        XCTAssertEqual(lengthFilter.minLength, 10)
        XCTAssertEqual(lengthFilter.maxLength, 40)
        XCTAssertEqual(FASTQOperationRowCommand.finalCommand(for: result), row)
    }

    func testATwoInputBatchRowIsACommandScriptWithOneLinePerBundleInImportOrder() async throws {
        let first = try makeSourceBundle(named: "Sample A")
        let second = try makeSourceBundle(named: "Sample B")
        let request = FASTQDerivativeRequest.reverseComplement
        let firstBundle = try await importOutput(of: request, on: first, named: "Sample A-rc")
        let secondBundle = try await importOutput(of: request, on: second, named: "Sample B-rc")
        let launch = derivativeLaunch(request, on: [first, second])
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch,
            executedInvocations: [],
            importedURLs: [firstBundle, secondBundle],
            groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)

        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        let expected = try [firstBundle, secondBundle].map {
            try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: $0)?.operation.toolCommand)
        }
        XCTAssertEqual(row.components(separatedBy: "\n"), expected, "one line per manifest in import order")
        let commands = try RecordedCLICommand.parseScript(row)
        XCTAssertEqual(commands.count, 2)
        let parsed = try commands.map { try XCTUnwrap($0 as? FastqReverseComplementSubcommand) }
        XCTAssertEqual(parsed.map(\.input), [first.bundleURL.path, second.bundleURL.path])
        XCTAssertEqual(
            parsed.map(\.output.output),
            [try payload(of: firstBundle).path, try payload(of: secondBundle).path]
        )
    }

    func testOutputsOfOneRunThatRecordTheSameCommandAppearOnce() async throws {
        // `fastq deacon-ribo -o` takes the folder that holds the published
        // bundles, so every bundle of the run records the same command.
        let source = try makeSourceBundle(named: "Sample 1")
        let request = FASTQDerivativeRequest.ribosomalRNAFilter(retention: .both, ensure: .none)
        let kept = try await importOutput(of: request, on: source, named: "Sample 1-norrna")
        let removed = try await importOutput(of: request, on: source, named: "Sample 1-rrna")
        let launch = derivativeLaunch(request, on: [source])
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [kept, removed], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)

        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        let manifestCommand = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: kept)?.operation.toolCommand)
        XCTAssertEqual(
            try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: removed)?.operation.toolCommand),
            manifestCommand,
            "both bundles record one command"
        )
        XCTAssertEqual(row, manifestCommand, "the duplicate line is dropped")
        XCTAssertEqual(try RecordedCLICommand.parseScript(row).count, 1)
    }

    // MARK: - Savont

    func testASavontRowNamesThePublishedFASTAAfterTheRun() throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let fasta = analyses.appendingPathComponent("Sample 1-savont.fasta")
        try ">cluster_1\nACGTACGTAC\n".write(to: fasta, atomically: true, encoding: .utf8)
        let launch = FASTQOperationLaunchRequest.savont(request: FASTQSavontClusteringRequest(
            inputURLs: [source.bundleURL],
            outputDirectoryURL: analyses,
            singleInputOutputName: fasta.lastPathComponent,
            threads: 2,
            qualityValueCutoff: 90,
            minimumClusterSize: 3,
            minimumReadLength: nil,
            maximumReadLength: nil,
            singleStrand: false
        ))
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: launch, outputTargetPath: fasta.path
        )
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [invocation], importedURLs: [fasta], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertTrue(begun.contains("<derived>"), "the row records the placeholder at begin: \(begun)")

        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)

        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertEqual(row, FASTQOperationCLIInvocationBuilder.commandLine(for: invocation))
        XCTAssertFalse(row.contains("<derived>"), row)
        let commands = try RecordedCLICommand.parseScript(row)
        XCTAssertEqual(commands.count, 1)
        let savont = try XCTUnwrap(commands.first as? FastqSavontClusterSubcommand)
        XCTAssertEqual(savont.output, fasta.path, "the command names the published file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savont.output))
        XCTAssertEqual(savont.input, source.bundleURL.path)
    }

    // MARK: - Demultiplex

    /// The Demultiplex Barcodes launch the dialog builds. It gives a demultiplex the per-input mode, and the
    /// run's folder comes back as its one imported URL with no grouped container.
    private func demultiplexLaunch(on source: (bundleURL: URL, fastqURL: URL)) -> FASTQOperationLaunchRequest {
        .derivative(
            request: .demultiplex(
                kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
            ),
            inputURLs: [source.bundleURL],
            outputMode: .perInput
        )
    }

    /// The words after `lungfish-cli fastq` that `FastqDemultiplexSubcommand` records for a cutadapt run at its
    /// default thresholds (`cliArguments` in `FastqCommand.swift`). The record always names the engine that ran,
    /// and it leaves out `--location`, `--error-rate`, `--threads` and the other options while they hold their defaults.
    private func demultiplexArguments(on source: (bundleURL: URL, fastqURL: URL), runFolder: URL) -> [String] {
        [
            "demultiplex", source.bundleURL.path, "--kit", "illumina-nextera", "--output", runFolder.path,
            "--engine", "cutadapt",
        ]
    }

    /// Writes the record `lungfish-cli fastq demultiplex` leaves at the root of its run folder, with the real
    /// writer (`CLIProvenanceSupport.recordSingleStepRun`). Its run command is `command`.
    private func writeDemultiplexRecord(in runFolder: URL, command: [String]) async throws {
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        let barcodeFile = runFolder.appendingPathComponent("bc01.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: barcodeFile, readCount: 2, readLength: 20)
        _ = try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq demultiplex",
            parameters: [:],
            toolName: "cutadapt",
            toolVersion: "5.0",
            command: command,
            inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: barcodeFile, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 1,
            stderr: nil,
            status: .completed,
            outputDirectory: runFolder
        )
    }

    func testDemultiplexRowTakesTheRecordedArgvAndLogsNoRecordsNoCommandLine() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let launch = demultiplexLaunch(on: source)
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-1", isDirectory: true)
        let arguments = demultiplexArguments(on: source, runFolder: runFolder)
        try await writeDemultiplexRecord(in: runFolder, command: [CLICommandIdentity.executableName, "fastq"] + arguments)
        // The record's first word is the one `checked` tests, and it comes from the record the real writer made.
        let recorded = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: runFolder)?.argv)
        XCTAssertEqual(recorded.first, CLICommandIdentity.executableName)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [runFolder], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertTrue(begun.contains("<derived>"), "the row records the placeholder at begin: \(begun)")
        let refinement = FASTQOperationRowCommand.refinement(for: result)
        FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

        // The record's reader spells a project path as the standardized URL does (`/var/...`), where the
        // fixtures spell it physically (`/private/var/...`), so the expected row is the argv the reader hands back.
        let expected = FASTQOperationCLIInvocationBuilder.commandLine(
            for: FASTQCLIInvocation(subcommand: recorded[1], arguments: Array(recorded.dropFirst(2)))
        )
        XCTAssertEqual(refinement, .replace(with: expected), "the row takes the argv the run's record holds")
        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertEqual(row, expected)
        XCTAssertFalse(row.contains("<derived>"), row)
        XCTAssertTrue(row.contains(runFolder.lastPathComponent), "the row names the run's folder: \(row)")
        XCTAssertTrue(row.contains("--output") && row.contains("Sample 1.lungfishfastq"), row)
        let logs = try XCTUnwrap(reporter.items.first).logs.map(\.message)
        XCTAssertFalse(logs.contains { $0.contains("records no command") }, "\(logs)")
        XCTAssertEqual(logs, [], "a replaced command logs nothing")
        let commands = try RecordedCLICommand.parseScript(row)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands.first is FastqDemultiplexSubcommand)
    }

    func testARecordedAbsoluteCLIPathShowsAsLungfishCLI() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-4", isDirectory: true)
        let arguments = demultiplexArguments(on: source, runFolder: runFolder)
        try await writeDemultiplexRecord(
            in: runFolder,
            command: ["/Applications/Lungfish.app/Contents/MacOS/\(CLICommandIdentity.executableName)", "fastq"] + arguments
        )
        let result = FASTQOperationExecutionResult(
            resolvedRequest: demultiplexLaunch(on: source),
            executedInvocations: [],
            importedURLs: [runFolder],
            groupedContainerURL: nil
        )

        let recorded = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: runFolder)?.argv)
        XCTAssertEqual(
            recorded.first, "/Applications/Lungfish.app/Contents/MacOS/\(CLICommandIdentity.executableName)",
            "the record keeps the CLI as it was launched"
        )
        let expected = FASTQOperationCLIInvocationBuilder.commandLine(
            for: FASTQCLIInvocation(subcommand: recorded[1], arguments: Array(recorded.dropFirst(2)))
        )
        XCTAssertTrue(expected.hasPrefix(CLICommandIdentity.executableName + " fastq demultiplex "), expected)
        XCTAssertEqual(FASTQOperationRowCommand.refinement(for: result), .replace(with: expected))
    }

    /// A Demultiplex Barcodes row is begun with its run folder in `-o`, since the folder is known before `begin`.
    /// The row of a demultiplex that fails is never refined, so this command is the one Copy CLI Command gives
    /// for it, and it runs the same demultiplex again.
    func testTheLaunchCommandOfADemultiplexNamesItsRunFolder() throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-3", isDirectory: true)
        let reporter = RecordingOperationReporter()
        _ = try beginRow(for: demultiplexLaunch(on: source), on: reporter, outputTargetPath: runFolder.path)

        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertFalse(row.contains("<derived>"), row)
        let shown = try XCTUnwrap(RecordedCLICommand.parseScript(row).first as? FastqDemultiplexSubcommand)
        XCTAssertEqual(shown.input, source.bundleURL.path)
        XCTAssertEqual(shown.output, runFolder.path, "the command names the run folder, not a placeholder")
    }

    func testADemultiplexFolderWithNoRecordKeepsTheBeginCommandAndSaysSo() throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let launch = demultiplexLaunch(on: source)
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-2", isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [runFolder], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        let refinement = FASTQOperationRowCommand.refinement(for: result)
        FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

        let reason = "demultiplex-2 holds no provenance record of its command"
        XCTAssertEqual(refinement, .keep(reason: reason))
        XCTAssertEqual(reporter.items.first?.cliCommand, begun)
        XCTAssertEqual(
            try XCTUnwrap(reporter.items.first).logs.map(\.message),
            ["The row keeps the command recorded at launch: \(reason)"]
        )
    }

    func testARunIsToldAsADemultiplexByItsRequestAndNotByItsFolderName() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-9", isDirectory: true)
        try await writeDemultiplexRecord(
            in: runFolder,
            command: [CLICommandIdentity.executableName, "fastq"] + demultiplexArguments(on: source, runFolder: runFolder)
        )
        // A length filter whose imported URL is named like a demultiplex run is a derivative: its folder has no manifest.
        let result = FASTQOperationExecutionResult(
            resolvedRequest: derivativeLaunch(.lengthFilter(min: 10, max: nil), on: [source]),
            executedInvocations: [],
            importedURLs: [runFolder],
            groupedContainerURL: nil
        )

        guard case .keep(let reason) = FASTQOperationRowCommand.refinement(for: result) else {
            return XCTFail("a derivative takes no command from a folder name")
        }
        XCTAssertTrue(reason.contains("records no command"), reason)
    }

    /// A word the record keeps as `<external>/<file name>` names a file the CLI cannot open. `checked` refuses it,
    /// for the derivative and Savont rows too, so the row keeps its launch command.
    func testADemultiplexRecordThatNamesAFileOutsideTheProjectKeepsTheBeginCommand() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-6", isDirectory: true)
        var arguments = demultiplexArguments(on: source, runFolder: runFolder)
        // The writer keeps a path outside the project as `<external>/<file name>`, which no reader resolves.
        arguments[3] = "<external>/barcodes.csv"
        try await writeDemultiplexRecord(in: runFolder, command: [CLICommandIdentity.executableName, "fastq"] + arguments)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: demultiplexLaunch(on: source), executedInvocations: [],
            importedURLs: [runFolder], groupedContainerURL: nil
        )

        XCTAssertEqual(
            FASTQOperationRowCommand.refinement(for: result),
            .keep(reason: "a recorded command is not a lungfish-cli command that names its final output")
        )
    }

    /// A threshold the run recorded because it is not a default stays in the row, and the row parses back to the
    /// run's own values (`docs/contracts/CLI-EQUIVALENCE.md` asks that the parsed values equal the run's configuration).
    func testANonDefaultThresholdTheRunRecordedStaysInTheRow() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let runFolder = root.appendingPathComponent("Project.lungfish/Analyses/demultiplex-7", isDirectory: true)
        let arguments = demultiplexArguments(on: source, runFolder: runFolder)
            + ["--location", "5prime", "--error-rate", "0.2", "--no-trim", "--threads", "8"]
        try await writeDemultiplexRecord(in: runFolder, command: [CLICommandIdentity.executableName, "fastq"] + arguments)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: demultiplexLaunch(on: source), executedInvocations: [],
            importedURLs: [runFolder], groupedContainerURL: nil
        )

        guard case .replace(let command) = FASTQOperationRowCommand.refinement(for: result) else {
            return XCTFail("a record with non-default thresholds is a record the row takes")
        }
        let parsed = try XCTUnwrap(RecordedCLICommand.parseScript(command).first as? FastqDemultiplexSubcommand)
        XCTAssertEqual(parsed.engine, "cutadapt")
        XCTAssertEqual(parsed.location, "5prime")
        XCTAssertEqual(parsed.errorRate, 0.2)
        XCTAssertTrue(parsed.noTrim)
        XCTAssertEqual(parsed.threads, 8)
    }

    // MARK: - A refinement never makes a row worse

    func testAGroupedResultKeepsTheBeginCommand() throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let demultiplex = FASTQDerivativeRequest.demultiplex(
            kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
            maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
            trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
        )
        let launch = FASTQOperationLaunchRequest.derivative(
            request: demultiplex, inputURLs: [source.bundleURL], outputMode: .groupedResult
        )
        let container = root.appendingPathComponent("Project.lungfish/Analyses/demux", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [container], groupedContainerURL: container
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        let refinement = FASTQOperationRowCommand.refinement(for: result)
        FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

        XCTAssertEqual(refinement, .notApplicable)
        XCTAssertNil(FASTQOperationRowCommand.finalCommand(for: result))
        XCTAssertEqual(reporter.items.first?.cliCommand, begun)
    }

    func testAManifestWithoutALungfishCLICommandKeepsTheBeginCommandAndLogsWhy() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        // An adapter FASTA has no `lungfish-cli` option, so the manifest records no command.
        let request = FASTQDerivativeRequest.adapterTrim(
            mode: .fastaFile, sequence: nil, sequenceR2: nil, fastaFilename: "adapters.fasta"
        )
        let noCommand = try await importOutput(of: request, on: source, named: "Sample 1-adapters")
        XCTAssertNil(FASTQBundle.loadDerivedManifest(in: noCommand)?.operation.toolCommand)
        // A launch that is not a derivative records the app's import form.
        let staging = root.appendingPathComponent("work-app-import", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("LF1001.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: staged, readCount: 2, readLength: 20)
        try DialogRowStagedProvenance.write(
            argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
            inputURL: source.fastqURL,
            outputURL: staged,
            in: staging
        )
        let appImport = try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: root.appendingPathComponent("Project.lungfish/Derived/LF1001.\(FASTQBundle.directoryExtension)"),
            originalRequest: .ontFluidigmSampleSplit(
                inputFASTQURL: source.bundleURL,
                barcodeDefinitionsURL: root.appendingPathComponent("samples.csv"),
                threads: 2
            ),
            sourceInputURL: source.bundleURL
        )
        let appImportCommand = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: appImport)?.operation.toolCommand)
        XCTAssertTrue(appImportCommand.hasPrefix("'\(LungfishAppIdentity.recordedToolName)' "), appImportCommand)

        let launch = derivativeLaunch(.lengthFilter(min: 10, max: nil), on: [source])
        for bundle in [noCommand, appImport] {
            let result = FASTQOperationExecutionResult(
                resolvedRequest: launch, executedInvocations: [], importedURLs: [bundle], groupedContainerURL: nil
            )
            let reporter = RecordingOperationReporter()
            let id = try beginRow(for: launch, on: reporter)
            let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
            let refinement = FASTQOperationRowCommand.refinement(for: result)
            FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

            guard case .keep = refinement else {
                return XCTFail("\(bundle.lastPathComponent): \(refinement)")
            }
            XCTAssertEqual(reporter.items.first?.cliCommand, begun, bundle.lastPathComponent)
            XCTAssertEqual(reporter.items.first?.logs.count, 1, "one line says why the row keeps its command")
            XCTAssertNil(FASTQOperationRowCommand.finalCommand(for: result))
        }
    }

    func testAnImportedBundleThatNoLongerExistsKeepsTheBeginCommand() async throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let request = FASTQDerivativeRequest.lengthFilter(min: 10, max: 40)
        let bundleURL = try await importOutput(of: request, on: source, named: "Sample 1-length")
        try FileManager.default.removeItem(at: bundleURL)
        let launch = derivativeLaunch(request, on: [source])
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [bundleURL], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        let refinement = FASTQOperationRowCommand.refinement(for: result)
        FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

        guard case .keep = refinement else { return XCTFail("\(refinement)") }
        XCTAssertEqual(reporter.items.first?.cliCommand, begun)
        XCTAssertEqual(reporter.items.first?.logs.count, 1)
    }

    func testASavontFASTAThatNoLongerExistsKeepsTheBeginCommand() throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        let missing = analyses.appendingPathComponent("Sample 1-savont.fasta")
        let launch = FASTQOperationLaunchRequest.savont(request: FASTQSavontClusteringRequest(
            inputURLs: [source.bundleURL],
            outputDirectoryURL: analyses,
            singleInputOutputName: missing.lastPathComponent,
            threads: 2,
            qualityValueCutoff: 90,
            minimumClusterSize: 3,
            minimumReadLength: nil,
            maximumReadLength: nil,
            singleStrand: false
        ))
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: launch, outputTargetPath: missing.path
        )
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [invocation], importedURLs: [], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        let refinement = FASTQOperationRowCommand.refinement(for: result)
        FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

        guard case .keep = refinement else { return XCTFail("\(refinement)") }
        XCTAssertEqual(reporter.items.first?.cliCommand, begun)
    }

    func testARunOfAnotherKindKeepsItsCommandAndLogsNothing() throws {
        let source = try makeSourceBundle(named: "Sample 1")
        let launch = FASTQOperationLaunchRequest.refreshQCSummary(inputURLs: [source.bundleURL])
        let result = FASTQOperationExecutionResult(
            resolvedRequest: launch, executedInvocations: [], importedURLs: [source.bundleURL], groupedContainerURL: nil
        )

        let reporter = RecordingOperationReporter()
        let id = try beginRow(for: launch, on: reporter)
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        let refinement = FASTQOperationRowCommand.refinement(for: result)
        FASTQOperationRowCommand.apply(refinement, to: id, reporter: reporter)

        XCTAssertEqual(refinement, .notApplicable)
        XCTAssertEqual(reporter.items.first?.cliCommand, begun)
        XCTAssertEqual(reporter.items.first?.logs.count, 0)
    }
}
