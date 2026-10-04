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
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
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

    /// Registers the dialog row for `launch` on `reporter`, as the launch site does.
    private func beginRow(for launch: FASTQOperationLaunchRequest, on reporter: RecordingOperationReporter) throws -> UUID {
        try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(launch.operationDisplayTitle)",
            request: launch,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
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
        XCTAssertTrue(appImportCommand.hasPrefix("Lungfish.app "), appImportCommand)

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
