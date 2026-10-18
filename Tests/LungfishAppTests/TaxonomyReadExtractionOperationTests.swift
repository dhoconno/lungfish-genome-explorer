// TaxonomyReadExtractionOperationTests.swift - The classifier extraction row and its recorded command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Classifier read extraction registers its row through
// `TaxonomyReadExtractionAction.beginExtractionOperation` (R4). File and
// bundle destinations record a `lungfish-cli extract reads` command that
// reproduces the run. The bundle command used to write a relative `-o`, so a
// pasted command put the bundle in the shell's working folder. It now names
// the project's Extractions folder, where the app writes, and new bundles
// record that corrected command as their provenance command. Clipboard and
// share record the command that writes the scratch file the app copies.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxonomyReadExtractionOperationTests: XCTestCase {
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    private func context() -> TaxonomyReadExtractionAction.Context {
        TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish/Analyses/esviritu run/results.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001803"], taxIds: [])],
            suggestedName: "my-extract",
            routeContext: routeContext
        )
    }

    private func recordedItem(
        destination: ExtractionDestination,
        options: ExtractionOptions = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        let cli = TaxonomyReadExtractionAction.buildCLIString(
            context: context(),
            options: options,
            destination: destination,
            scratchFile: scratchFile(for: destination)
        )
        var launchedID: UUID?
        TaxonomyReadExtractionAction.beginExtractionOperation(
            context: context(),
            cliCommand: cli,
            reporter: reporter
        ) { launchedID = $0 }
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extract Reads — EsViritu")
        XCTAssertEqual(item.operationType, .taxonomyExtraction)
        XCTAssertNil(item.targetBundleURL, "extraction writes new files and locks no bundle")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        return item
    }

    func testFileDestinationRecordsARunnableCommand() throws {
        let outputURL = URL(fileURLWithPath: "/tmp/lane 1a1/out reads.fastq")

        let item = try recordedItem(
            destination: .file(outputURL),
            options: ExtractionOptions(format: .fastq, includeUnmappedMates: true)
        )

        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertTrue(command.byClassifier)
        XCTAssertEqual(command.classifierTool, "esviritu")
        XCTAssertEqual(command.classifierResult, "/tmp/lane 1a1/Project.lungfish/Analyses/esviritu run/results.sqlite")
        XCTAssertEqual(command.classifierSamples, ["S1"])
        XCTAssertEqual(command.classifierAccessionsRaw, ["NC_001803"])
        XCTAssertEqual(command.classifierFormat, "fastq")
        XCTAssertTrue(command.includeUnmappedMates)
        XCTAssertEqual(command.output, outputURL.path)
        XCTAssertFalse(command.createBundle)
    }

    func testBundleDestinationRecordsACommandThatWritesIntoTheProjectExtractionsFolder() throws {
        let projectRoot = URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish", isDirectory: true)

        let item = try recordedItem(destination: .bundle(
            projectRoot: projectRoot,
            displayName: "my-extract",
            metadata: ExtractionMetadata(sourceDescription: "my-extract", toolName: "EsViritu")
        ))

        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli extract reads --by-classifier --tool esviritu"
                + " --result '/tmp/lane 1a1/Project.lungfish/Analyses/esviritu run/results.sqlite'"
                + " --sample S1 --accession NC_001803 --read-format fastq"
                + " --bundle --bundle-name my-extract"
                + " -o '/tmp/lane 1a1/Project.lungfish/Extractions/my-extract.fastq'"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertTrue(command.createBundle)
        XCTAssertEqual(command.bundleName, "my-extract")
        XCTAssertEqual(command.output, "/tmp/lane 1a1/Project.lungfish/Extractions/my-extract.fastq")
    }

    /// The CLI creates its bundle beside the `-o` file, so `-o` must sit in
    /// the folder the app creates bundles in.
    func testBundleOutputDirectoryMatchesTheFolderTheAppWritesBundlesInto() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "extraction-bundle-folder")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let extractions = projectRoot.appendingPathComponent(ClassifierReadResolver.extractionsFolderName, isDirectory: true)

        for root in [projectRoot, extractions] {
            XCTAssertEqual(
                TaxonomyReadExtractionAction.bundleOutputDirectory(projectRoot: root).standardizedFileURL.path,
                try ClassifierReadResolver.bundleDestinationDirectory(projectRoot: root).standardizedFileURL.path
            )
        }
    }

    /// The scratch file a clipboard or share route hands the command, where
    /// ``ClassifierExtractionCopyRoute`` puts it, and nil for a file or bundle.
    private func scratchFile(for destination: ExtractionDestination) -> URL? {
        switch destination {
        case .file, .bundle:
            return nil
        case .clipboard:
            return URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish/.tmp/classifier-clipboard-1/my-extract.fastq")
        case .share(let shareRoot):
            return shareRoot.appendingPathComponent("shares/1/my-extract.fastq")
        }
    }

    /// Clipboard and share record the command that writes the file the app
    /// then copies, so Copy CLI Command replays the extraction (Phase 2.12
    /// lane 12.11, which closes classifier-extract-clipboard-share).
    func testClipboardAndShareRecordTheCommandThatWritesTheirScratchFile() throws {
        let destinations: [ExtractionDestination] = [
            .clipboard(format: .fastq, cap: TaxonomyReadExtractionAction.clipboardReadCap),
            .share(tempDirectory: URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish/.lungfish/.tmp")),
        ]
        for destination in destinations {
            let item = try recordedItem(destination: destination)
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
            XCTAssertTrue(command.byClassifier)
            XCTAssertEqual(command.classifierTool, "esviritu")
            XCTAssertEqual(command.classifierSamples, ["S1"])
            XCTAssertEqual(command.output, scratchFile(for: destination)?.path)
            XCTAssertEqual(command.globalOptions.outputFormat, .json, "the row shows the command's events")
            XCTAssertFalse(command.createBundle)
        }
    }

    /// The route makes the clipboard's folder in the project's `.tmp` and a
    /// share's in a new folder of the share root, and runs the arguments the
    /// row records.
    func testTheCopyRouteWritesIntoTheProjectsScratchAndRunsTheRecordedCommand() throws {
        let root = try TestTempDirectory.make(prefix: "extraction-copy-route")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/esviritu run/results.sqlite")
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: result,
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001803"], taxIds: [])],
            suggestedName: "my-extract"
        )
        let options = ExtractionOptions(format: .fastq)
        let shareRoot = project.appendingPathComponent(".lungfish/.tmp", isDirectory: true)
        let folders: [(ExtractionDestination, URL)] = [
            (.clipboard(format: .fastq, cap: 10), ProjectTempDirectory.tempRoot(for: project)),
            (.share(tempDirectory: shareRoot), shareRoot.appendingPathComponent("shares", isDirectory: true)),
        ]
        for (destination, parent) in folders {
            let route = try XCTUnwrap(
                try ClassifierExtractionCopyRoute.make(destination: destination, context: context, options: options)
            )
            XCTAssertEqual(
                route.scratchDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path,
                parent.resolvingSymlinksInPath().path
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: route.scratchDirectory.path), "the route makes its folder")
            XCTAssertEqual(route.scratchFile.lastPathComponent, "concatenated.fastq", "the name a shared file had before")
            let cli = TaxonomyReadExtractionAction.buildCLIString(
                context: context, options: options, destination: destination, scratchFile: route.scratchFile
            )
            XCTAssertEqual(try RouteParityHarness.arguments(ofLine: cli), route.arguments, "the runner runs what the row records")
        }
        XCTAssertNil(try ClassifierExtractionCopyRoute.make(destination: .file(result), context: context, options: options))
    }
}
