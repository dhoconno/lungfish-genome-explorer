// AppDelegateClassificationOperationTests.swift - begin() sites in AppDelegate+Classification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The TaxTriage launch registers its row through a static begin helper (R4),
// and the Kraken2 and EsViritu launches through the CLI route's. None
// declares a lock, so no real OperationCenter refuses them, and a reporter
// that refuses every begin proves each launch closure sits behind the
// `.started` case. The command a single Kraken2 or EsViritu sample records is
// the argv of the Workflow builder (`ClassificationCLIInvocationBuilder`,
// `EsVirituCLIInvocationBuilder`), which the real CLI parser reads back with
// the run's values, and a Kraken2 batch records one such command per sample.
// A single-sample TaxTriage row records a command that parses the same way.
// The multi-sample TaxTriage row has no command that reproduces the run, so
// it records nil, and its test pins the gap with `assertCLIParityGap`. When a
// command lands, the pin fails and prompts a deliberate test change. Phase
// 2.10 lane A32 moved the Kraken2 and EsViritu tests off the begin helpers
// that only tests called, and the CLI route's title, first detail and type
// are held as literals by ClassifierLaunchRouteTests.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class AppDelegateClassificationOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish")
    private let databaseURL = URL(fileURLWithPath: "/tmp/lane 1a2/Databases/Viral DB")

    private func makeRouteContext() -> OperationRouteContext {
        OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
    }

    private func importURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/lane 1a2/Imports/\(name)")
    }

    private func analysisURL(_ name: String) -> URL {
        projectURL.appendingPathComponent("Analyses").appendingPathComponent(name)
    }

    // MARK: - Kraken2

    /// The command a Kraken2 sample records is the builder's argv, and the real CLI parser reads
    /// the run's values back from it. The row's title, first detail, type, lock and route are the
    /// CLI route's, which ClassifierLaunchRouteTests holds as literals.
    func testKraken2CommandIsTheBuildersArgvAndTheCLIParsesIt() throws {
        let inputs = [importURL("Sample 1_R1.fastq.gz"), importURL("Sample 1_R2.fastq.gz")]
        let outputURL = analysisURL("kraken2-2026-10-02")
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: inputs,
            isPairedEnd: true,
            databaseName: "Viral",
            databasePath: databaseURL,
            brackenProfileRequest: .automaticDefault,
            confidence: 0.35,
            minimumHitGroups: 3,
            threads: 6,
            memoryMapping: true,
            quickMode: true,
            outputDirectory: outputURL,
            extraArguments: ["--minimum-base-quality", "20"]
        )
        let recorded = ClassifierLaunchReference.kraken2Command(for: config)
        XCTAssertTrue(
            recorded.hasPrefix("lungfish-cli kraken2 classify "),
            "E11 names the command kraken2 classify, after lungfish-cli and not the legacy executable name lungfish"
        )
        let command = try RecordedCLICommand.parse(recorded, as: ClassifyCommand.self)
        XCTAssertEqual(command.databaseName, "Viral", "--db is the registry name the CLI resolves")
        XCTAssertEqual(command.fastqFiles, inputs.map(\.path))
        XCTAssertEqual(command.outputDir, outputURL.path)
        XCTAssertTrue(command.pairedEnd)
        XCTAssertEqual(command.confidence, 0.35)
        XCTAssertEqual(command.minHitGroups, 3)
        XCTAssertEqual(command.globalOptions.threads, 6)
        XCTAssertTrue(command.memoryMapping)
        XCTAssertTrue(command.quickMode)
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(command.extraArgs), ["--minimum-base-quality", "20"])
        XCTAssertTrue(command.profile)
        XCTAssertEqual(command.brackenReadLength, BrackenProfileRequest.automaticDefault.readLength)
        XCTAssertEqual(command.brackenThreshold, BrackenProfileRequest.automaticDefault.threshold)
        // The argv is the builder's whole, the same mapping the batch replay
        // command uses. The builder spells kraken2 classify since 2.7 (E11).
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: recorded),
            ClassificationCLIInvocationBuilder.build(for: config).arguments
        )
    }

    func testKraken2TitleNamesTheGoalAndTheFirstInput() throws {
        let cases: [(ClassificationConfig.Goal, String)] = [
            (.classify, "Classifying"),
            (.profile, "Profiling"),
            (.extract, "Classifying (extract)"),
        ]
        for (goal, label) in cases {
            let config = ClassificationConfig(
                goal: goal,
                inputFiles: [importURL("Sample 1.lungfishfastq"), importURL("Sample 2.lungfishfastq")],
                isPairedEnd: false,
                databaseName: "Viral",
                databasePath: databaseURL,
                outputDirectory: analysisURL("kraken2-2026-10-02")
            )

            let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [config], projectURL: projectURL))
            XCTAssertEqual(launch.title, "\(label) Sample 1.lungfishfastq")
        }

        let noInput = ClassificationConfig(
            inputFiles: [],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: databaseURL,
            outputDirectory: analysisURL("kraken2-2026-10-02")
        )
        let noInputLaunch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [noInput], projectURL: projectURL))
        XCTAssertEqual(noInputLaunch.title, "Classifying reads")
    }

    // MARK: - Kraken2 batch

    func testKraken2BatchCommandIsOneConfiguredCommandPerSample() throws {
        let firstInput = importURL("Sample 1.lungfishfastq")
        let pairedInputs = [importURL("Sample 2_R1.fastq.gz"), importURL("Sample 2_R2.fastq.gz")]
        let first = ClassificationConfig(
            inputFiles: [firstInput],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: databaseURL,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            outputDirectory: analysisURL("kraken2-batch-2026-10-02/Sample 1")
        )
        let second = ClassificationConfig(
            inputFiles: pairedInputs,
            isPairedEnd: true,
            databaseName: "Viral",
            databasePath: databaseURL,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            outputDirectory: analysisURL("kraken2-batch-2026-10-02/Sample 2")
        )
        // One `kraken2 classify` per sample (R3, E11). The row used to record
        // one command with the database path in `--db`, no output folder and
        // every input of every sample, which the CLI could not run as the
        // batch ran.
        let lines = try XCTUnwrap(ClassifierLaunchReference.kraken2BatchCommand(for: [first, second])).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "one command per sample")
        for (line, config) in zip(lines, [first, second]) {
            let command = try RecordedCLICommand.parse(line, as: ClassifyCommand.self)
            XCTAssertEqual(command.databaseName, "Viral", "--db is the registry name the CLI resolves")
            XCTAssertEqual(command.fastqFiles, config.inputFiles.map(\.path))
            XCTAssertEqual(command.outputDir, config.outputDirectory.path)
            XCTAssertEqual(command.pairedEnd, config.isPairedEnd)
            XCTAssertEqual(command.confidence, 0.2)
            XCTAssertEqual(command.minHitGroups, 2)
            XCTAssertEqual(command.globalOptions.threads, 4)
            XCTAssertEqual(
                try RecordedCLICommand.arguments(of: line),
                ClassificationCLIInvocationBuilder.build(for: config).arguments,
                "the line is the builder's kraken2 classify argv for the sample"
            )
        }
    }

    func testEmptyKraken2BatchRecordsNoCommand() {
        XCTAssertNil(AppDelegate.classificationBatchCLICommand(for: []))
    }

    func testKraken2BatchTitleCountsSamples() throws {
        let config = ClassificationConfig(
            inputFiles: [importURL("Sample 1.lungfishfastq")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: databaseURL,
            outputDirectory: analysisURL("kraken2-batch-2026-10-02/Sample 1")
        )
        let reporter = RecordingOperationReporter()

        AppDelegate.beginClassificationBatchOperation(configs: [config], routeContext: nil, reporter: reporter) { _ in }

        XCTAssertEqual(try XCTUnwrap(reporter.items.first).title, "Classification Batch (1 sample)")
    }

    // MARK: - EsViritu

    func testEsVirituCommandIsTheBuildersArgvAndTheCLIParsesIt() throws {
        let imports = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-1k1-esviritu-\(UUID().uuidString)/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imports.deletingLastPathComponent()) }
        let inputs = [imports.appendingPathComponent("Sample 1_R1.fastq"), imports.appendingPathComponent("Sample 1_R2.fastq")]
        for (index, input) in inputs.enumerated() {
            try "@r1/\(index + 1)\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
        }
        let config = EsVirituConfig(
            inputFiles: inputs,
            isPairedEnd: true,
            sampleName: "Sample 1",
            outputDirectory: analysisURL("esviritu-2026-10-02/Sample 1"),
            databasePath: URL(fileURLWithPath: "/tmp/lane 1a2/Databases/EsViritu"),
            qualityFilter: false,
            threads: 6,
            extraArguments: ["--min_read_len", "120"],
            readFormat: .paired
        )
        let recorded = ClassifierLaunchReference.esVirituCommand(for: config)
        // The command records every setting the run uses, the same arguments the
        // run's provenance records (R3).
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: recorded),
            ["esviritu", "detect"] + EsVirituCLIInvocationBuilder.esVirituDetectCLIArguments(for: config)
        )
        let command = try RecordedCLICommand.parse(recorded, as: EsVirituCommand.DetectSubcommand.self)
        XCTAssertEqual(command.inputFiles, inputs.map(\.path))
        XCTAssertEqual(command.sampleName, "Sample 1")
        XCTAssertEqual(command.readFormat, .paired)
        XCTAssertEqual(command.databasePath, config.databasePath.path)
        XCTAssertEqual(command.outputDir, config.outputDirectory.path)
        XCTAssertEqual(command.globalOptions.threads, 6)
        XCTAssertTrue(command.noQC)
        XCTAssertEqual(command.extraArgs, "--min_read_len 120")
        // The pasted command runs EsViritu with the arguments the run used.
        let cliConfig = try command.makeConfigForTesting(
            databaseURL: URL(fileURLWithPath: try XCTUnwrap(command.databasePath)),
            outputDirectory: URL(fileURLWithPath: try XCTUnwrap(command.outputDir))
        )
        XCTAssertEqual(cliConfig.esVirituArguments(), config.esVirituArguments())
    }

    func testEsVirituRowForABundleReplaysThroughTheCLIResolution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-1k1-esviritu-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = directory.appendingPathComponent("Sample 1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readsURL = bundleURL.appendingPathComponent("Sample 1.fastq")
        try "@r1\nACGT\n+\nIIII\n@r2\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FASTQBundle.isBundleURL(bundleURL))
        let databaseURL = directory.appendingPathComponent("EsViritu DB", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("esviritu-out", isDirectory: true)
        let config = EsVirituConfig(
            inputFiles: [bundleURL],
            isPairedEnd: false,
            sampleName: "Sample 1",
            outputDirectory: outputURL,
            databasePath: databaseURL,
            readFormat: .unpaired
        )
        // The wizard hands the run a `.lungfishfastq` bundle, so the command
        // is `esviritu detect --input <bundle>`. The command resolves the
        // bundle to the file it holds, as the run does, and EsViritu accepts
        // the result (R3). It used to refuse the bundle as a directory.
        let command = try RecordedCLICommand.parse(
            ClassifierLaunchReference.esVirituCommand(for: config), as: EsVirituCommand.DetectSubcommand.self
        )
        XCTAssertEqual(command.inputFiles, [bundleURL.path])
        XCTAssertEqual(command.readFormat, .unpaired)
        let resolved = try await EsVirituCommand.DetectSubcommand.resolveExecutionInputs(
            for: [bundleURL],
            materializationDirectory: outputURL.appendingPathComponent(
                EsVirituCommand.DetectSubcommand.materializationDirectoryName,
                isDirectory: true
            ),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        XCTAssertEqual(resolved.executionInputURLs, [readsURL.standardizedFileURL])
        var cliConfig = try command.makeConfigForTesting(databaseURL: databaseURL, outputDirectory: outputURL)
        cliConfig.inputFiles = resolved.executionInputURLs
        XCTAssertNoThrow(try cliConfig.validate())
    }

    /// A bundle whose plan holds separate R1 and R2 files runs `-p paired`, and
    /// one `--input` cannot carry `--paired`. The row records `--read-format
    /// auto`, so the CLI plans the bundle and hands EsViritu the same pair.
    func testEsVirituRowForABundleOfPairsRecordsReadFormatAutoAndNeverPaired() throws {
        let bundle = importURL("Sample 1.lungfishfastq")
        var config = EsVirituConfig(
            inputFiles: [bundle],
            isPairedEnd: true,
            sampleName: "Sample 1",
            outputDirectory: analysisURL("esviritu-2026-10-02/Sample 1"),
            databasePath: URL(fileURLWithPath: "/tmp/lane 1a2/Databases/EsViritu"),
            readFormat: .paired
        )
        config.plansReadSet = true

        let recorded = ClassifierLaunchReference.esVirituCommand(for: config)
        let command = try RecordedCLICommand.parse(recorded, as: EsVirituCommand.DetectSubcommand.self)
        XCTAssertEqual(command.inputFiles, [bundle.path], "the row names the bundle the user chose")
        XCTAssertEqual(command.readFormat, .auto)
        XCTAssertFalse(command.pairedEnd, "--paired names two files only")
        XCTAssertFalse(recorded.contains("--paired"))

        // Without the planner the row would name `paired` for one input, which
        // `esviritu detect` refuses, so a pasted command could not reproduce the run.
        config.plansReadSet = false
        let unplanned = EsVirituCLIInvocationBuilder.esVirituDetectCLIArguments(for: config)
        let index = try XCTUnwrap(unplanned.firstIndex(of: "--read-format"))
        XCTAssertEqual(unplanned[index + 1], "paired")
        XCTAssertNotNil(EsVirituCommand.DetectSubcommand.inputCountError(format: .paired, fileCount: 1))
    }

    func testEsVirituBatchRowRecordsNoCommandAndPinsTheParityGap() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let pairedInputs = [importURL("Sample 1_R1.fastq.gz"), importURL("Sample 1_R2.fastq.gz")]
        let singleInput = importURL("Sample 2.fastq.gz")
        let first = EsVirituConfig(
            inputFiles: pairedInputs,
            isPairedEnd: true,
            sampleName: "Sample 1",
            outputDirectory: analysisURL("esviritu-batch-2026-10-02/Sample 1"),
            databasePath: URL(fileURLWithPath: "/tmp/lane 1a2/Databases/EsViritu"),
            readFormat: .paired
        )
        let second = EsVirituConfig(
            inputFiles: [singleInput],
            isPairedEnd: false,
            sampleName: "Sample 2",
            outputDirectory: analysisURL("esviritu-batch-2026-10-02/Sample 2"),
            databasePath: URL(fileURLWithPath: "/tmp/lane 1a2/Databases/EsViritu"),
            readFormat: .unpaired
        )
        var launchedID: UUID?

        AppDelegate.beginEsVirituBatchOperation(
            configs: [first, second],
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "EsViritu Batch (2 samples)")
        XCTAssertEqual(item.initialDetail, "Starting EsViritu batch\u{2026}")
        XCTAssertEqual(item.operationType, .classification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        // cli-parity-gap: esviritu-batch. The batch runs EsViritu once per
        // sample with each sample's own read format, and no command does. The
        // row used to record one `esviritu detect` with every input after
        // `--input` and the first sample's name, which the CLI would run as a
        // single unpaired sample. It records no command until a batch command
        // lands. The closest reproduction is one `esviritu detect` per sample.
        XCTAssertNil(item.cliCommand, "the row records no command it cannot reproduce")
        assertCLIParityGap(item.cliCommand, id: "esviritu-batch")
    }

    func testEsVirituBatchArgumentsFallBackToABatchSampleName() {
        XCTAssertEqual(EsVirituCLIInvocationBuilder.esVirituBatchCLIArguments(for: []), ["--input", "--sample", "batch"])
    }

    // MARK: - TaxTriage

    private func makeTaxTriageSample(
        _ sampleID: String,
        paired: Bool = false,
        platform: TaxTriageConfig.Platform = .illumina
    ) -> TaxTriageSample {
        TaxTriageSample(
            sampleId: sampleID,
            fastq1: importURL("\(sampleID)_R1.fastq.gz"),
            fastq2: paired ? importURL("\(sampleID)_R2.fastq.gz") : nil,
            platform: platform
        )
    }

    /// Records the one-sample row for `config` and checks that the recorded
    /// command parses and builds the Nextflow arguments the run builds.
    private func assertOneSampleCommandReproducesTheRun(
        _ config: TaxTriageConfig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TaxTriageCommand.RunSubcommand {
        let reporter = RecordingOperationReporter()

        AppDelegate.beginTaxTriageOperation(config: config, routeContext: nil, reporter: reporter) { _ in }

        let item = try XCTUnwrap(reporter.items.first, file: file, line: line)
        let command = try RecordedCLICommand.parse(
            item.cliCommand,
            as: TaxTriageCommand.RunSubcommand.self,
            file: file,
            line: line
        )
        let cliConfig = try command.makeConfigForTesting()
        XCTAssertEqual(cliConfig.samples, config.samples, file: file, line: line)
        XCTAssertEqual(cliConfig.outputDirectory.path, config.outputDirectory.path, file: file, line: line)
        XCTAssertEqual(cliConfig.kraken2DatabasePath?.path, config.kraken2DatabasePath?.path, file: file, line: line)
        XCTAssertEqual(
            cliConfig.nextflowPipelineArguments(),
            config.nextflowPipelineArguments(),
            "the pasted command must build the same Nextflow arguments as the run",
            file: file,
            line: line
        )
        return command
    }

    func testTaxTriageRowRecordsItsRowAndACommandThatBuildsTheRunsNextflowArguments() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let config = TaxTriageConfig(
            samples: [makeTaxTriageSample("Sample 1", paired: true, platform: .oxford)],
            platform: .oxford,
            outputDirectory: analysisURL("taxtriage-2026-10-02"),
            kraken2DatabasePath: databaseURL,
            topHitsCount: 5,
            k2Confidence: 0.35,
            rank: "G",
            skipAssembly: false,
            skipKrona: true,
            maxMemory: "32.GB",
            maxCpus: 6,
            extraArguments: ["--use_denovo", "yes please"],
            removeTaxids: "9606, 10090"
        )
        var launchedID: UUID?

        AppDelegate.beginTaxTriageOperation(
            config: config,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "TaxTriage (1 sample)")
        XCTAssertEqual(item.initialDetail, "Starting TaxTriage pipeline\u{2026}")
        XCTAssertEqual(item.operationType, .classification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: TaxTriageCommand.RunSubcommand.self)
        XCTAssertEqual(command.input, importURL("Sample 1_R1.fastq.gz").path)
        XCTAssertEqual(command.input2, importURL("Sample 1_R2.fastq.gz").path)
        XCTAssertEqual(command.sampleId, "Sample 1")
        XCTAssertEqual(command.outputDir, analysisURL("taxtriage-2026-10-02").path)
        XCTAssertEqual(command.databasePath, databaseURL.path)
        XCTAssertEqual(command.platform, .oxford)
        XCTAssertEqual(command.confidence, 0.35)
        XCTAssertEqual(command.topHits, 5)
        XCTAssertEqual(command.rank, "G")
        XCTAssertTrue(command.noSkipAssembly)
        XCTAssertFalse(command.skipAssembly)
        XCTAssertTrue(command.skipKrona)
        XCTAssertEqual(command.normalizedRemoveTaxids, "9606 10090")
        XCTAssertEqual(command.maxMemory, "32.GB")
        XCTAssertEqual(command.maxCpus, 6)
        XCTAssertEqual(command.nfProfile, "docker")
        XCTAssertEqual(command.revision, (try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())?.revision)
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(command.extraArgs), ["--use_denovo", "yes please"])

        _ = try assertOneSampleCommandReproducesTheRun(config)
    }

    func testTaxTriageSingleEndRunWithDefaultSettingsRecordsNoOptionalFlags() throws {
        let config = TaxTriageConfig(
            samples: [makeTaxTriageSample("Sample 1")],
            outputDirectory: analysisURL("taxtriage-2026-10-02"),
            kraken2DatabasePath: databaseURL
        )
        let reporter = RecordingOperationReporter()

        AppDelegate.beginTaxTriageOperation(config: config, routeContext: nil, reporter: reporter) { _ in }

        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)
        for flag in ["--input2", "--no-skip-assembly", "--skip-krona", "--remove-taxids", "--extra-args"] {
            XCTAssertFalse(recorded.contains(flag), "a default run records no \(flag)")
        }
        let command = try assertOneSampleCommandReproducesTheRun(config)
        XCTAssertNil(command.input2)
        XCTAssertEqual(command.platform, .illumina)
    }

    /// The row names the bundle the user chose, never a scratch file the run
    /// deletes. `taxtriage run` plans the bundle itself, as the launch does.
    func testTaxTriageRowForABundleNamesTheBundleTheUserChose() throws {
        let bundle = importURL("Sample 1.lungfishfastq")
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "Sample 1", fastq1: bundle)],
            outputDirectory: analysisURL("taxtriage-2026-10-02"),
            kraken2DatabasePath: databaseURL
        )

        let command = try assertOneSampleCommandReproducesTheRun(config)

        XCTAssertEqual(command.input, bundle.path)
        XCTAssertNil(command.input2)
        XCTAssertEqual(command.sampleId, "Sample 1")
        let reporter = RecordingOperationReporter()
        AppDelegate.beginTaxTriageOperation(config: config, routeContext: nil, reporter: reporter) { _ in }
        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertFalse(recorded.contains("taxtriage-inputs"), "no scratch folder of the run")
        XCTAssertFalse(recorded.contains(".lungfish-"), "no scratch folder of the run")
    }

    func testTaxTriageHostRemovalInExtraArgumentsIsNotRecordedTwice() throws {
        // The verbatim extra arguments win over the host taxa field, as in
        // `TaxTriageConfig.effectiveRemoveTaxids`, so the command carries the
        // extra arguments alone.
        let config = TaxTriageConfig(
            samples: [makeTaxTriageSample("Sample 1")],
            outputDirectory: analysisURL("taxtriage-2026-10-02"),
            kraken2DatabasePath: databaseURL,
            extraArguments: ["--remove_taxids", "2"],
            removeTaxids: "9606"
        )
        let reporter = RecordingOperationReporter()

        AppDelegate.beginTaxTriageOperation(config: config, routeContext: nil, reporter: reporter) { _ in }

        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertFalse(recorded.contains("--remove-taxids"))
        let command = try assertOneSampleCommandReproducesTheRun(config)
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(command.extraArgs), ["--remove_taxids", "2"])
    }

    func testTaxTriageMultiSampleRowRecordsNoCommandAndPinsTheParityGap() throws {
        let reporter = RecordingOperationReporter()
        let config = TaxTriageConfig(
            samples: [
                makeTaxTriageSample("Sample 1", paired: true),
                makeTaxTriageSample("Sample 2"),
            ],
            outputDirectory: analysisURL("taxtriage-2026-10-02"),
            kraken2DatabasePath: databaseURL,
            removeTaxids: "9606"
        )

        AppDelegate.beginTaxTriageOperation(config: config, routeContext: nil, reporter: reporter) { _ in }

        // cli-parity-gap: taxtriage-multi-sample. `taxtriage run` takes one
        // `--input` or one `--samplesheet`, and the app runs several samples
        // one after another through `TaxTriageSerialBatchRunner`. No single
        // command reproduces that. The row used to record a flat `--input`
        // list that the CLI rejects. It records no command until a batch
        // command lands. The closest reproduction is `taxtriage run` once per
        // sample.
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "TaxTriage (2 samples)")
        XCTAssertNil(item.cliCommand, "the row records no command it cannot reproduce")
        assertCLIParityGap(item.cliCommand, id: "taxtriage-multi-sample")
        XCTAssertNil(AppDelegate.taxTriageCLICommand(for: config))
    }

    // MARK: - Sites with no lock launch nothing when the begin is refused

    func testSitesWithNoLockLaunchNothingWhenTheBeginIsRefused() throws {
        // No real center refuses these rows, because they request no lock. A
        // reporter that refuses every begin proves each launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let classification = ClassificationConfig(
            inputFiles: [importURL("Sample 1.lungfishfastq")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: databaseURL,
            outputDirectory: analysisURL("kraken2-2026-10-02")
        )
        let esViritu = EsVirituConfig(
            inputFiles: [importURL("Sample 1.fastq.gz")],
            isPairedEnd: false,
            sampleName: "Sample 1",
            outputDirectory: analysisURL("esviritu-2026-10-02"),
            databasePath: URL(fileURLWithPath: "/tmp/lane 1a2/Databases/EsViritu")
        )
        let taxTriage = TaxTriageConfig(
            samples: [makeTaxTriageSample("Sample 1")],
            outputDirectory: analysisURL("taxtriage-2026-10-02"),
            kraken2DatabasePath: databaseURL
        )
        var launched: [String] = []

        func check(_ name: String, _ result: OperationStartResult) {
            guard case .refused = result else { return XCTFail("\(name) must report the refusal") }
        }

        // The CLI route's launches, one sample and a batch of two for each tool.
        let routes: [(String, ClassifierCLIRouteLaunch?)] = [
            ("Kraken2", .kraken2(configs: [classification], projectURL: projectURL)),
            ("Kraken2 batch", .kraken2(configs: [classification, classification], projectURL: projectURL)),
            ("EsViritu", .esViritu(configs: [esViritu], projectURL: projectURL)),
            ("EsViritu batch", .esViritu(configs: [esViritu, esViritu], projectURL: projectURL)),
        ]
        for (name, launch) in routes {
            check(name, AppDelegate.beginClassifierCLIRouteOperation(
                try XCTUnwrap(launch, name), routeContext: nil, reporter: reporter
            ) { _ in launched.append(name) })
        }
        check("TaxTriage", AppDelegate.beginTaxTriageOperation(
            config: taxTriage, routeContext: nil, reporter: reporter
        ) { _ in launched.append("TaxTriage") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 5)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
