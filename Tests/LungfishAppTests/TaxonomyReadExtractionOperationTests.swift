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
// share have no CLI equivalent, and their tests pin the GUI-only note.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
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
            destination: destination
        )
        var launchedID: UUID?
        TaxonomyReadExtractionAction.beginExtractionOperation(
            context: context(),
            cliCommand: TaxonomyReadExtractionAction.rowCLICommand(cli, destination: destination),
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

    func testClipboardAndShareRecordNoCommandAsAParityGap() throws {
        let destinations: [ExtractionDestination] = [
            .clipboard(format: .fastq, cap: TaxonomyReadExtractionAction.clipboardReadCap),
            .share(tempDirectory: URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish/.lungfish/.tmp")),
        ]
        for destination in destinations {
            let item = try recordedItem(destination: destination)
            // The CLI writes files, not the clipboard or a share sheet, so
            // the row records no command.
            XCTAssertNil(item.cliCommand)
            assertCLIParityGap(item.cliCommand, id: "classifier-extract-clipboard-share")
        }
    }
}
