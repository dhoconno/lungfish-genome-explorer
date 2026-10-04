// SamplesheetReadSetParityTests.swift - lungfish-cli reads a bundle for EsViritu and TaxTriage the way the app does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decisions 1 and 4 of 2026-10-03 (docs/contracts/READ-PAIRING.md and
// docs/contracts/CLI-EQUIVALENCE.md). For every bundle layout, the command
// the Operations panel records for an EsViritu or TaxTriage sample reads the
// same files, paired the same way, as the app's own launch of that tool. The
// app side runs the production resolvers (`resolvedEsVirituConfig` and
// `resolvedTaxTriageConfig`), the command side parses the recorded line with
// the shipped parser and runs the steps `esviritu detect` and `taxtriage run`
// run. Read names say what each read is, as in ReadSetFixtures. The tests sit
// beside BundleResolutionCLIParityTests, which holds the same checks for
// Kraken2, and use their own fixtures.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
import LungfishKitTestSupport
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class SamplesheetReadSetParityTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "samplesheet-read-set-parity")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Every layout of docs/contracts/READ-PAIRING.md a sample can have.
    private var shapes: [(name: String, bundle: URL)] {
        [
            ("L1 single", fixtures.singleRoot),
            ("L2 interleaved", fixtures.interleavedRoot),
            ("L3 mixed root", fixtures.mixedRoot),
            ("L4 chunked", fixtures.chunkedRoot),
            ("L4 Nanopore chunks named as mates", fixtures.nanoporeChunkedRoot),
            ("L4 Illumina chunks named R1 and R2", fixtures.namedPairChunkedRoot),
            ("L5b paired", fixtures.pairedDerivative),
            ("L5c merge", fixtures.mergeDerivative),
            ("L5d repair", fixtures.repairDerivative),
            ("L6 subset of single", fixtures.subsetOfSingle),
            ("L6 subset of interleaved", fixtures.subsetOfInterleaved),
            ("L6 subset of merge", fixtures.subsetOfMerge),
            ("L6 subset of repair", fixtures.subsetOfRepair),
        ]
    }

    // MARK: - EsViritu

    /// The wizard plans each sample, the launch resolves it, and the recorded
    /// `esviritu detect` command resolves it again through the CLI. Both give
    /// the same files and the same `-p` format.
    func testEsVirituDetectPlansTheReadSetTheAppsLaunchDoes() async throws {
        for (shape, bundle) in shapes {
            let sample = try XCTUnwrap(MetagenomicsSampleGrouper.group([bundle]).first, shape)
            let readPlan = await EsVirituSampleReadPlan.planned(for: sample)
            var wizardConfig = EsVirituConfig(
                inputFiles: sample.inputFiles,
                isPairedEnd: sample.isPairedEnd,
                sampleName: "sample",
                outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
                databasePath: root.appendingPathComponent("db", isDirectory: true),
                readFormat: readPlan.format,
                inputLayout: readPlan.layout
            )
            wizardConfig.plansReadSet = readPlan.plansReadSet

            // The app.
            let app = try await AppDelegate().resolvedEsVirituConfig(
                wizardConfig,
                tempDirectory: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true),
                materializer: fixtures.materializer
            )

            // The command the Operations panel records, parsed by the shipped
            // parser and run as `esviritu detect` runs it.
            let reporter = RecordingOperationReporter()
            AppDelegate.beginEsVirituOperation(config: wizardConfig, routeContext: nil, reporter: reporter) { _ in }
            let recorded = try XCTUnwrap(reporter.items.first?.cliCommand, shape)
            let command = try RecordedCLICommand.parse(recorded, as: EsVirituCommand.DetectSubcommand.self)
            let inputs = try CLIClassificationFolderResolver.expandInputArguments(command.inputFiles, recursive: command.recursive)
            let cliInputsDirectory = wizardConfig.outputDirectory.appendingPathComponent(
                EsVirituCommand.DetectSubcommand.materializationDirectoryName,
                isDirectory: true
            )
            let cliResolved = try await EsVirituCommand.DetectSubcommand.resolveExecutionInputs(
                for: inputs,
                materializationDirectory: cliInputsDirectory,
                materializer: fixtures.materializer
            )
            var cli = try command.makeConfigForTesting(
                databaseURL: wizardConfig.databasePath,
                outputDirectory: wizardConfig.outputDirectory
            )
            cli.inputFiles = cliResolved.executionInputURLs
            cli.recordInputLineage(cliResolved)
            _ = try await command.planReadSet(
                inputURLs: inputs,
                executionInputURLs: cliResolved.executionInputURLs,
                config: &cli,
                materializationDirectory: cliInputsDirectory
            )

            XCTAssertEqual(cli.readFormat, app.readFormat, "\(shape): the same -p format")
            XCTAssertEqual(
                try cli.inputFiles.map(ReadSetFixtures.readNames(in:)),
                try app.inputFiles.map(ReadSetFixtures.readNames(in:)),
                "\(shape): the same files, in the same order"
            )
            XCTAssertEqual(flags(cli.esVirituArguments()), flags(app.esVirituArguments()), "\(shape): the same flags")
            XCTAssertEqual(cli.readSetPlan?.singleReadReason, app.readSetPlan?.singleReadReason, "\(shape): the same reason")
            XCTAssertEqual(cli.readSetPlan?.composition, app.readSetPlan?.composition, "\(shape): the same fragments")
            XCTAssertEqual(
                cli.readSetPlan?.provenanceParameters.keys.sorted(),
                app.readSetPlan?.provenanceParameters.keys.sorted(),
                "\(shape): the same plan in provenance"
            )
            // The command names the planner exactly when the app's plan needs it,
            // and never records `--paired` for one input.
            XCTAssertEqual(command.readFormat == .auto, wizardConfig.plansReadSet, "\(shape): recorded with --read-format auto only when planned")
            XCTAssertFalse(command.pairedEnd, "\(shape): --paired names two files only")
        }
    }

    /// A deinterleaved bundle is a pair, and every other sample EsViritu cannot
    /// pair runs in one file, so the recorded command asks the CLI to plan it.
    func testEsVirituRecordsReadFormatAutoForTheSamplesItsPlannerDecides() async throws {
        let planned = ["L3 mixed root", "L4 chunked", "L5b paired", "L5c merge", "L5d repair", "L6 subset of merge"]
        for (shape, bundle) in shapes where planned.contains(shape) {
            let sample = try XCTUnwrap(MetagenomicsSampleGrouper.group([bundle]).first, shape)
            let readPlan = await EsVirituSampleReadPlan.planned(for: sample)
            XCTAssertTrue(readPlan.plansReadSet, "\(shape): the wizard hands the plan to the planner")
        }
        let single = try XCTUnwrap(MetagenomicsSampleGrouper.group([fixtures.singleRoot]).first)
        let singlePlan = await EsVirituSampleReadPlan.planned(for: single)
        XCTAssertFalse(singlePlan.plansReadSet, "single reads need no planner")
        let interleaved = try XCTUnwrap(MetagenomicsSampleGrouper.group([fixtures.interleavedRoot]).first)
        let interleavedPlan = await EsVirituSampleReadPlan.planned(for: interleaved)
        XCTAssertFalse(interleavedPlan.plansReadSet, "one interleaved file needs no planner")
    }

    // MARK: - TaxTriage

    /// The launch resolves each sample, and the recorded `taxtriage run`
    /// command resolves it again through the CLI. Both give the same samplesheet
    /// row after the pipeline splits a strictly interleaved file.
    func testTaxTriageRunPlansTheReadSetTheAppsLaunchDoes() async throws {
        for (shape, bundle) in shapes {
            let sample = TaxTriageSample(sampleId: "sample", fastq1: bundle)
            let outputDirectory = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
            let wizardConfig = TaxTriageConfig(
                samples: [sample],
                outputDirectory: outputDirectory,
                kraken2DatabasePath: root.appendingPathComponent("db", isDirectory: true)
            )

            // The app.
            let app = try await AppDelegate().resolvedTaxTriageConfig(
                wizardConfig,
                tempDirectory: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true),
                materializer: fixtures.materializer
            )

            // The command the Operations panel records, parsed by the shipped
            // parser and run as `taxtriage run --input` runs it.
            let reporter = RecordingOperationReporter()
            AppDelegate.beginTaxTriageOperation(config: wizardConfig, routeContext: nil, reporter: reporter) { _ in }
            let recorded = try XCTUnwrap(reporter.items.first?.cliCommand, shape)
            let command = try RecordedCLICommand.parse(recorded, as: TaxTriageCommand.RunSubcommand.self)
            XCTAssertEqual(command.input, bundle.path, "\(shape): the row names the input the user chose")
            let inputs = try CLIClassificationFolderResolver.expandInputArguments(
                [try XCTUnwrap(command.input)],
                recursive: command.recursive
            )
            let cliSamples = try await TaxTriageCommand.RunSubcommand.resolveSamples(
                inputs.map {
                    TaxTriageSample(
                        sampleId: TaxTriageCommand.RunSubcommand.sampleID(
                            for: $0,
                            explicitSampleID: command.sampleId,
                            totalSampleCount: inputs.count
                        ),
                        fastq1: $0,
                        platform: command.platform.toPlatform()
                    )
                },
                materializationDirectory: outputDirectory.appendingPathComponent(
                    TaxTriageCommand.RunSubcommand.materializationDirectoryName,
                    isDirectory: true
                ),
                materializer: fixtures.materializer
            )
            let cliConfig = TaxTriageConfig(samples: cliSamples, outputDirectory: outputDirectory)

            let appSample = try XCTUnwrap(app.samples.first, shape)
            let cliSample = try XCTUnwrap(cliConfig.samples.first, shape)
            XCTAssertEqual(cliSample.readLayout, appSample.readLayout, "\(shape): the same layout")
            XCTAssertEqual(cliSample.readSetPlan?.singleReadReason, appSample.readSetPlan?.singleReadReason, "\(shape): the same reason")
            XCTAssertEqual(cliSample.readSetPlan?.composition, appSample.readSetPlan?.composition, "\(shape): the same fragments")
            XCTAssertEqual(cliSample.readSetPlan?.sourceLayout, appSample.readSetPlan?.sourceLayout, "\(shape): the same source layout")

            // After the pipeline's own split of a strictly interleaved file.
            let appRow = try await samplesheetRow(app)
            let cliRow = try await samplesheetRow(cliConfig)
            XCTAssertEqual(cliRow.fastq1, appRow.fastq1, "\(shape): the same fastq_1")
            XCTAssertEqual(cliRow.fastq2, appRow.fastq2, "\(shape): the same fastq_2")
        }
    }

    // MARK: - Helpers

    /// The flags of an EsViritu argument list, with the file paths left out.
    private func flags(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.hasPrefix("/") }
    }

    private struct Row: Equatable {
        let fastq1: [String]
        let fastq2: [String]?
    }

    /// The samplesheet row `TaxTriagePipeline.run` writes for the first sample
    /// of `config`, as the record names of its files.
    private func samplesheetRow(_ config: TaxTriageConfig) async throws -> Row {
        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: config,
            splitRoot: root.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        )
        let entry = try XCTUnwrap(TaxTriagePipeline.samplesheetEntries(for: prepared.config).first)
        return Row(
            fastq1: try ReadSetFixtures.readNames(in: URL(fileURLWithPath: entry.fastq1Path)),
            fastq2: try entry.fastq2Path.map { try ReadSetFixtures.readNames(in: URL(fileURLWithPath: $0)) }
        )
    }
}
