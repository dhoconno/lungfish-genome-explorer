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
            try await assertTaxTriagePathsAgree(shape, TaxTriageSample(sampleId: "sample", fastq1: bundle), names: bundle.path)
        }
    }

    /// The coordinator's ruling of 2026-10-04. A file or chunk the user names
    /// is that file on both paths. Every member file of one bundle is that
    /// bundle on both paths. The preview of a virtual bundle names its bundle
    /// on both paths. The recorded command names the files the user chose.
    func testTaxTriageNamedFilesInsideABundleArePlannedTheSameOnBothPaths() async throws {
        let chunks = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: fixtures.chunkedRoot))
        let pairedR1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let pairedR2 = fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq")
        let unmergedR1 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R1.fastq")
        let unmergedR2 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq")
        let cases: [(String, URL, URL?)] = [
            ("one mate file", pairedR1, nil),
            ("one chunk", chunks[1], nil),
            ("every member file of a chunked root", chunks[0], chunks[1]),
            ("every member file of a paired derivative", pairedR1, pairedR2),
            ("part of a bundle's files", unmergedR1, unmergedR2),
            ("the preview of a virtual bundle", fixtures.subsetOfSingle.appendingPathComponent("preview.fastq"), nil),
        ]
        for (shape, first, second) in cases {
            try await assertTaxTriagePathsAgree(
                shape,
                TaxTriageSample(sampleId: "sample", fastq1: first, fastq2: second),
                names: first.path,
                names2: second?.path
            )
        }

        // The planned and the unplanned shapes differ in what they read.
        let one = try await appSample(TaxTriageSample(sampleId: "sample", fastq1: pairedR1))
        XCTAssertEqual(try ReadSetFixtures.readNames(in: one.fastq1), ["p1/1", "p2/1"])
        XCTAssertNil(one.fastq2)
        let all = try await appSample(TaxTriageSample(sampleId: "sample", fastq1: chunks[0], fastq2: chunks[1]))
        XCTAssertEqual(try ReadSetFixtures.readNames(in: all.fastq1), ["c1", "c2", "c3"])
        XCTAssertNil(all.fastq2)
        let preview = try await appSample(
            TaxTriageSample(sampleId: "sample", fastq1: fixtures.subsetOfSingle.appendingPathComponent("preview.fastq"))
        )
        XCTAssertEqual(try ReadSetFixtures.readNames(in: preview.fastq1), ["s1", "s3"])
    }

    // MARK: - Helpers

    /// The sample the app's TaxTriage launch resolves.
    private func appSample(_ sample: TaxTriageSample) async throws -> TaxTriageSample {
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        )
        let resolved = try await AppDelegate().resolvedTaxTriageConfig(
            config,
            tempDirectory: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true),
            materializer: fixtures.materializer
        )
        return try XCTUnwrap(resolved.samples.first)
    }

    /// Resolves `sample` through the app's launch and through the command the
    /// Operations panel records for it, parsed by the shipped parser and run as
    /// `taxtriage run --input` builds and resolves its samples, and requires
    /// the same layout, the same plan and the same samplesheet row.
    private func assertTaxTriagePathsAgree(
        _ shape: String,
        _ sample: TaxTriageSample,
        names: String,
        names2: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
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

        // The command the Operations panel records.
        let reporter = RecordingOperationReporter()
        AppDelegate.beginTaxTriageOperation(config: wizardConfig, routeContext: nil, reporter: reporter) { _ in }
        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand, shape, file: file, line: line)
        let command = try RecordedCLICommand.parse(recorded, as: TaxTriageCommand.RunSubcommand.self)
        XCTAssertEqual(command.input, names, "\(shape): the row names the input the user chose", file: file, line: line)
        XCTAssertEqual(command.input2, names2, "\(shape): the row names the second input the user chose", file: file, line: line)

        // The CLI builds its samples from `--input` and `--input2` as `run()` does.
        let inputs = try CLIClassificationFolderResolver.expandInputArguments(
            [try XCTUnwrap(command.input)],
            recursive: command.recursive
        )
        let unresolved: [TaxTriageSample]
        if let input2 = command.input2 {
            unresolved = [TaxTriageSample(
                sampleId: command.sampleId ?? sample.sampleId,
                fastq1: inputs[0],
                fastq2: URL(fileURLWithPath: input2),
                platform: command.platform.toPlatform()
            )]
        } else {
            unresolved = inputs.map {
                TaxTriageSample(
                    sampleId: TaxTriageCommand.RunSubcommand.sampleID(
                        for: $0,
                        explicitSampleID: command.sampleId,
                        totalSampleCount: inputs.count
                    ),
                    fastq1: $0,
                    platform: command.platform.toPlatform()
                )
            }
        }
        let cliSamples = try await TaxTriageCommand.RunSubcommand.resolveSamples(
            unresolved,
            materializationDirectory: outputDirectory.appendingPathComponent(
                TaxTriageCommand.RunSubcommand.materializationDirectoryName,
                isDirectory: true
            ),
            materializer: fixtures.materializer
        )
        let cliConfig = TaxTriageConfig(samples: cliSamples, outputDirectory: outputDirectory)

        let appSample = try XCTUnwrap(app.samples.first, shape, file: file, line: line)
        let cliSample = try XCTUnwrap(cliConfig.samples.first, shape, file: file, line: line)
        XCTAssertEqual(cliSample.readLayout, appSample.readLayout, "\(shape): the same layout", file: file, line: line)
        XCTAssertEqual(
            cliSample.readSetPlan?.singleReadReason,
            appSample.readSetPlan?.singleReadReason,
            "\(shape): the same reason",
            file: file,
            line: line
        )
        XCTAssertEqual(
            cliSample.readSetPlan?.composition,
            appSample.readSetPlan?.composition,
            "\(shape): the same fragments",
            file: file,
            line: line
        )
        XCTAssertEqual(
            cliSample.readSetPlan?.sourceLayout,
            appSample.readSetPlan?.sourceLayout,
            "\(shape): the same source layout",
            file: file,
            line: line
        )

        // After the pipeline's own split of a strictly interleaved file.
        let appRow = try await samplesheetRow(app)
        let cliRow = try await samplesheetRow(cliConfig)
        XCTAssertEqual(cliRow.fastq1, appRow.fastq1, "\(shape): the same fastq_1", file: file, line: line)
        XCTAssertEqual(cliRow.fastq2, appRow.fastq2, "\(shape): the same fastq_2", file: file, line: line)
    }


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
