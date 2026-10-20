// ViewerTaxonomyOperationTests.swift - begin() sites in ViewerViewController+Taxonomy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Kraken2 viewer registers two kinds of rows (R4). BLAST verification
// records the `lungfish-cli blast submit` command its search runs (Phase 2.12
// lane 12.10), and the in-process route kept for one release records
// `lungfish-cli blast verify` with the `--result-dir` it saves into. Batch
// extraction of a taxa collection records the `lungfish-cli extract
// taxa-collection` command that runs it (Phase 2.11 lane A66). Each test parses
// its command, and neither row locks a bundle.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
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

    /// Since Phase 2.12 (lane 12.10) the row records the `lungfish-cli blast submit` command its search runs. The
    /// row takes it once the read lookup has planned the search, the plan the site makes from the lookup's request.
    func testKraken2BlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "kraken2-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        // A batch sample saves into its own folder, not the configured output folder.
        let sampleDirectory = project.appendingPathComponent("Analyses/kraken2 batch/Sample 1", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "Influenza A virus", taxId: 11320,
            sequences: [(id: "read_1", sequence: "ACGTACGTAC"), (id: "read_2", sequence: "GGCCTTAAGG")],
            entrezQuery: nil, sequenceMates: [:],
            acceptedTaxIds: [11320, 211044], acceptedTaxonNames: ["Influenza A virus", "H1N1 subtype"],
            relatedTaxIds: [11520], relatedTaxonNames: ["Influenza B virus"]
        )
        let plan = try ViewerViewController.kraken2BlastSubmitPlan(
            request: request, projectURL: project, resultDirectory: sampleDirectory, sample: "Sample 1"
        )
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginKraken2BlastVerificationOperation(
            taxonName: "Influenza A virus", cliCommand: plan.cliCommand, reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Influenza A virus")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let stage = URL(fileURLWithPath: command.queryPath).deletingLastPathComponent()
        XCTAssertTrue(stage.lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(stage.deletingLastPathComponent().lastPathComponent, ".tmp", "the query file sits in the project's .tmp")
        let output = URL(fileURLWithPath: command.outputPath).deletingLastPathComponent()
        XCTAssertEqual(output.lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().path, sampleDirectory.path, "the search sits in the sample's result folder")
        XCTAssertEqual(command.sourceResult, sampleDirectory.path, "--source-result is the Kraken2 result folder")
        XCTAssertEqual(command.label, "Influenza A virus")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.sample, "Sample 1")
        XCTAssertNil(command.contig)
        XCTAssertEqual(command.acceptedTaxIds, [11320, 211044], "hits are judged against the clade")
        XCTAssertEqual(command.acceptedNames, ["Influenza A virus", "H1N1 subtype"])
        XCTAssertEqual(command.relatedTaxIds, [11520], "and the genus relatives")
        XCTAssertEqual(command.relatedNames, ["Influenza B virus"])
        XCTAssertEqual(command.subsampleCount, 2, "the reads the lookup drew")
        XCTAssertEqual(command.subsampleSeed, 0)
        XCTAssertEqual(command.database, "nt", "the search keeps the in-process row's database (BIO 3)")
        XCTAssertTrue(plan.arguments.contains("--database"), "the recorded argv names the database (BIO 4)")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(
            String(decoding: plan.queryData, as: UTF8.self), ">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n",
            "the reads reach BLAST as a file"
        )
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
