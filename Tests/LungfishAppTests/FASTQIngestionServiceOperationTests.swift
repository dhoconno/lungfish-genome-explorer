// FASTQIngestionServiceOperationTests.swift - begin() sites in FASTQIngestionService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The three FASTQ ingestion launches register their Operations panel rows
// through static begin helpers (R4). None of them declares a bundle lock, so a
// real center never refuses them, and a recording reporter that holds a lock
// stands in for the refusal. The two bundle imports record
// `lungfish-cli import fastq` commands, which the tests parse with the
// real CLI parser and compare with the values the run uses. The in-place
// ingestion has no command that reproduces it, so its test pins today's
// command as a CLI parity gap.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class FASTQIngestionServiceOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2l3/Project.lungfish", isDirectory: true)
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2l3/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    /// Checks what every ingestion row shares and returns the one row.
    private func assertIngestionRow(
        _ reporter: RecordingOperationReporter,
        launchedID: UUID?,
        title: String,
        detail: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RecordingOperationReporter.Item {
        let item = try XCTUnwrap(reporter.items.first, file: file, line: line)
        XCTAssertEqual(reporter.items.count, 1, file: file, line: line)
        XCTAssertEqual(launchedID, item.id, file: file, line: line)
        XCTAssertEqual(item.title, title, file: file, line: line)
        XCTAssertEqual(item.initialDetail, detail, file: file, line: line)
        XCTAssertEqual(item.operationType, .ingestion, file: file, line: line)
        XCTAssertNil(item.targetBundleURL, "ingestion locks no bundle", file: file, line: line)
        XCTAssertEqual(item.additionalLockedBundleURLs, [], file: file, line: line)
        XCTAssertEqual(item.routeContext, routeContext, file: file, line: line)
        return item
    }

    // MARK: - In-place ingestion (site 24)

    private let downloadedURL = URL(fileURLWithPath: "/tmp/lane 1a2l3/Downloads/SRR1770413_1.fastq.gz")
    private let downloadedMateURL = URL(fileURLWithPath: "/tmp/lane 1a2l3/Downloads/SRR1770413_2.fastq.gz")

    private func recordedInPlaceRow(
        pairingMode: FASTQIngestionConfig.PairingMode,
        pairedFile: URL?
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?
        let result = FASTQIngestionService.beginInPlaceIngestionOperation(
            url: downloadedURL,
            pairingMode: pairingMode,
            pairedFile: pairedFile,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }
        let item = try assertIngestionRow(
            reporter,
            launchedID: launchedID,
            title: "FASTQ Ingestion: SRR1770413",
            detail: "Preparing..."
        )
        XCTAssertEqual(result.startedID, item.id)
        return item
    }

    func testInPlaceIngestionRecordsAnIngestionRowNamedForTheFile() throws {
        _ = try recordedInPlaceRow(pairingMode: .singleEnd, pairedFile: nil)
    }

    func testInPlaceIngestionRecordsTheImportCommandAsAParityGap() throws {
        let item = try recordedInPlaceRow(pairingMode: .singleEnd, pairedFile: nil)

        // CLI parity gap. The run clumpifies and compresses the file in place,
        // deletes the original, writes the FASTQ metadata sidecar and applies no
        // quality binning (FASTQIngestionConfig defaults to none). No command
        // reproduces that. The recorded command parses, but it would build a
        // new bundle under Imports in the file's folder and bin with illumina4.
        // The closest command is `debug fastq-ingest` with `--binning none
        // --delete-originals`, which runs the same pipeline and leaves the
        // sidecar unwritten. When a command covers the in-place run, record it
        // and replace this pin with a parse test of its values.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli import fastq '/tmp/lane 1a2l3/Downloads/SRR1770413_1.fastq.gz'"
                + " --project '/tmp/lane 1a2l3/Downloads' --platform auto --pairing single"
                + " --format json --quality-binning illumina4 --compression balanced"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(command.input, [downloadedURL.path])
        XCTAssertEqual(command.project, downloadedURL.deletingLastPathComponent().path)
        XCTAssertEqual(command.qualityBinning, "illumina4", "the in-place run applies no quality binning")
    }

    func testInPlaceIngestionCommandNamesTheMateOnlyForAPairedRun() throws {
        let paired = try recordedInPlaceRow(pairingMode: .pairedEnd, pairedFile: downloadedMateURL)
        let pairedCommand = try RecordedCLICommand.parse(paired.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(pairedCommand.input, [downloadedURL.path, downloadedMateURL.path])
        XCTAssertEqual(pairedCommand.pairing, "paired")

        // The run reads a second file only in paired-end mode.
        let single = try recordedInPlaceRow(pairingMode: .singleEnd, pairedFile: downloadedMateURL)
        let singleCommand = try RecordedCLICommand.parse(single.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(singleCommand.input, [downloadedURL.path])
        XCTAssertEqual(singleCommand.pairing, "single")
    }

    func testRefusedInPlaceIngestionLaunchesNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = FASTQIngestionService.beginInPlaceIngestionOperation(
            url: downloadedURL,
            pairingMode: .singleEnd,
            pairedFile: nil,
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    // MARK: - Single-file import (site 25)

    private let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2l3/Incoming/Sample 7_R1.fastq.gz")

    private func recordedSingleFileRow() throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?
        let result = FASTQIngestionService.beginSingleFileImportOperation(
            sourceURL: sourceURL,
            projectDirectory: projectURL,
            bundleName: "Sample 7",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }
        let item = try assertIngestionRow(
            reporter,
            launchedID: launchedID,
            title: "FASTQ Import: Sample 7",
            detail: "Preparing import workspace\u{2026}"
        )
        XCTAssertEqual(result.startedID, item.id)
        return item
    }

    func testSingleFileImportRecordsACommandThatParsesWithTheRunsValues() throws {
        let item = try recordedSingleFileRow()

        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(command.input, [sourceURL.path])
        XCTAssertEqual(command.project, projectURL.path)
        XCTAssertEqual(command.name, "Sample 7", "the run passes --name, and the command used to leave it out")
        XCTAssertEqual(command.platform, "auto", "nobody chose the platform, so the CLI infers it (it used to pass illumina)")
        XCTAssertEqual(command.pairing, "auto", "nobody chose the pairing, so the CLI detects it")
        XCTAssertEqual(command.qualityBinning, "illumina4")
        XCTAssertEqual(command.compression, "balanced")
        XCTAssertEqual(command.recipe, "none")
        XCTAssertNil(command.clumpingTool)
        XCTAssertFalse(command.noOptimizeStorage)
        XCTAssertFalse(command.force)
    }

    func testSingleFileImportRecordsTheArgumentsTheRunExecutes() throws {
        let item = try recordedSingleFileRow()

        // `runIngestAndBundle(sourceURL:...)` hands this pair and configuration to
        // the pair run, which executes the arguments below. The pair run is
        // asynchronous and spawns the CLI, so the test rebuilds its arguments.
        let runArguments = FASTQIngestionService.cliImportArguments(
            pair: FASTQFilePair(r1: sourceURL, r2: nil),
            projectDirectory: projectURL,
            importConfig: FASTQIngestionService.legacySingleFileImportConfiguration(for: sourceURL),
            bundleName: "Sample 7"
        )
        XCTAssertEqual(item.cliCommand, CLIImportRunner.commandLine(arguments: runArguments))
    }

    func testRefusedSingleFileImportLaunchesNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = FASTQIngestionService.beginSingleFileImportOperation(
            sourceURL: sourceURL,
            projectDirectory: projectURL,
            bundleName: "Sample 7",
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    // MARK: - Import with the Import sheet settings (site 26)

    private let pair = FASTQFilePair(
        r1: URL(fileURLWithPath: "/tmp/lane 1a2l3/Incoming/Sample 9_R1.fastq.gz"),
        r2: URL(fileURLWithPath: "/tmp/lane 1a2l3/Incoming/Sample 9_R2.fastq.gz")
    )

    private func importConfig(skipClumpify: Bool, clumpingTool: ClumpingTool = .default) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [pair.r1, pair.r2!],
            detectedPlatform: .illumina,
            confirmedPlatform: .oxfordNanopore,
            platformIsUserChoice: true,
            pairingMode: .pairedEnd,
            pairingModeIsUserChoice: true,
            qualityBinning: .eightLevel,
            skipClumpify: skipClumpify,
            clumpingTool: clumpingTool,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: "vsp2",
            compressionLevel: .maximum
        )
    }

    private func recordedPairRow(
        config: FASTQImportConfiguration,
        forceReplace: Bool
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?
        let result = FASTQIngestionService.beginFASTQPairImportOperation(
            pair: pair,
            projectDirectory: projectURL,
            bundleName: "Sample 9 2",
            importConfig: config,
            forceReplace: forceReplace,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }
        let item = try assertIngestionRow(
            reporter,
            launchedID: launchedID,
            title: "FASTQ Import: Sample 9 2",
            detail: "Preparing import workspace\u{2026}"
        )
        XCTAssertEqual(result.startedID, item.id)
        return item
    }

    func testPairImportRecordsACommandThatParsesWithTheImportSheetSettings() throws {
        let item = try recordedPairRow(config: importConfig(skipClumpify: false, clumpingTool: .trimGalore), forceReplace: true)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(command.input, [pair.r1.path, pair.r2!.path])
        XCTAssertEqual(command.project, projectURL.path)
        XCTAssertEqual(command.name, "Sample 9 2")
        XCTAssertEqual(command.platform, "ont")
        XCTAssertEqual(command.pairing, "paired")
        XCTAssertEqual(command.qualityBinning, "eightLevel")
        XCTAssertEqual(command.compression, "maximum")
        XCTAssertEqual(command.recipe, "vsp2")
        XCTAssertEqual(command.clumpingTool, "trim-galore")
        XCTAssertFalse(command.noOptimizeStorage)
        XCTAssertTrue(command.force, "the user chose Replace in the duplicate dialog")
    }

    func testPairImportRecordsSkippedStorageOptimizationAndNoForceByDefault() throws {
        let item = try recordedPairRow(config: importConfig(skipClumpify: true), forceReplace: false)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertTrue(command.noOptimizeStorage)
        XCTAssertNil(command.clumpingTool)
        XCTAssertFalse(command.force, "--force is passed only after the user chose Replace")
    }

    func testPairImportRecordsTheArgumentsTheRunExecutes() throws {
        let config = importConfig(skipClumpify: false)
        let item = try recordedPairRow(config: config, forceReplace: true)

        // `_runCLIImport` builds exactly these arguments and hands them to `CLIImportRunner`.
        let runArguments = FASTQIngestionService.cliImportArguments(
            pair: pair,
            projectDirectory: projectURL,
            importConfig: config,
            bundleName: "Sample 9 2",
            force: true
        )
        XCTAssertEqual(item.cliCommand, CLIImportRunner.commandLine(arguments: runArguments))
    }

    func testRefusedPairImportLaunchesNothing() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = FASTQIngestionService.beginFASTQPairImportOperation(
            pair: pair,
            projectDirectory: projectURL,
            bundleName: "Sample 9",
            importConfig: importConfig(skipClumpify: false),
            forceReplace: false,
            routeContext: routeContext,
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
