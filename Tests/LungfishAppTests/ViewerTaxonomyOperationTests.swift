// ViewerTaxonomyOperationTests.swift - begin() sites in ViewerViewController+Taxonomy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Kraken2 viewer registers two kinds of rows (R4). BLAST verification
// records a `lungfish-cli blast verify` command, now with the `--result-dir`
// the app saves into. Batch extraction of a taxa collection records the
// `lungfish-cli extract taxa-collection` command that runs it (Phase 2.11 lane
// A66), and its test parses that command. Neither locks a bundle.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ViewerTaxonomyOperationTests: XCTestCase {
    private func makeClassificationResult() -> ClassificationResult {
        let directory = URL(fileURLWithPath: "/tmp/lane 1a1/Analyses/kraken2 run", isDirectory: true)
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0,
            parentTaxId: nil
        )
        return ClassificationResult(
            config: ClassificationConfig(
                inputFiles: [directory.appendingPathComponent("reads.fastq")],
                isPairedEnd: false,
                databaseName: "test-db",
                databasePath: directory.appendingPathComponent("db"),
                outputDirectory: directory
            ),
            tree: TaxonTree(root: root, unclassifiedNode: nil, totalReads: 100),
            reportURL: directory.appendingPathComponent("classification.kreport"),
            outputURL: directory.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }

    // MARK: - BLAST verification

    func testKraken2BlastVerificationRecordsARunnableCommandWithTheResultFolder() throws {
        let reporter = RecordingOperationReporter()
        let result = makeClassificationResult()
        let source = URL(fileURLWithPath: "/tmp/lane 1a1/Imports/Sample 1.lungfishfastq/reads.fastq")
        // A batch sample saves into its own folder, not the configured output folder.
        let sampleDirectory = URL(fileURLWithPath: "/tmp/lane 1a1/Analyses/kraken2 batch/Sample 1", isDirectory: true)
        var launchedID: UUID?

        ViewerViewController.beginKraken2BlastVerificationOperation(
            taxonName: "Influenza A virus",
            classResult: result,
            sourceInputs: [source],
            taxId: 11320,
            readCount: 20,
            resultDirectory: sampleDirectory,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Influenza A virus")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.VerifySubcommand.self)
        XCTAssertEqual(command.kreportFile, result.reportURL.path)
        XCTAssertEqual(command.krakenOutput, result.outputURL.path)
        XCTAssertEqual(command.sourcePaths, [source.path])
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.readCount, 20)
        XCTAssertTrue(command.includeChildren, "the app always includes descendant taxa")
        XCTAssertEqual(command.resultDirectory, sampleDirectory.path, "the app saves the verification under --result-dir")
    }

    // MARK: - Taxa collection batch extraction

    func testTaxaCollectionExtractionRecordsTheCommandThatReplaysIt() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a1/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        let result = makeClassificationResult()
        let collection = TaxaCollection.respiratoryViruses
        let outputDirectory = result.config.outputDirectory.appendingPathComponent("extracted-\(collection.id)")
        let arguments = ViewerViewController.taxaCollectionExtractionArguments(
            collection: collection,
            resultDirectory: result.config.outputDirectory,
            outputDirectory: outputDirectory
        )
        var launchedID: UUID?

        ViewerViewController.beginTaxaCollectionExtractionOperation(
            collection: collection,
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extract Respiratory Viruses")
        XCTAssertEqual(item.operationType, .taxonomyExtraction)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // The recorded command is the argv the run launches, and the real parser reads it back
        // with the collection's taxa in order. A path with a space is quoted.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractTaxaCollectionSubcommand.self)
        XCTAssertEqual(item.cliCommand?.hasPrefix("lungfish-cli extract taxa-collection --result '/tmp/lane 1a1/"), true)
        XCTAssertEqual(command.result, result.config.outputDirectory.path)
        XCTAssertEqual(command.collectionID, "respiratory-viruses")
        XCTAssertEqual(command.collectionName, "Respiratory Viruses")
        XCTAssertEqual(command.outputDirectory, outputDirectory.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the row shows the command's events")
        let parsed = try command.targets.map(ExtractTaxaCollectionSubcommand.parseTarget)
        XCTAssertEqual(parsed.map(\.taxId), collection.taxa.map(\.taxId))
        XCTAssertEqual(parsed.map(\.includeChildren), collection.taxa.map(\.includeChildren))
        XCTAssertEqual(parsed.map(\.displayName), collection.taxa.map(\.displayName))
        XCTAssertFalse(collection.taxa.isEmpty)
    }
}
