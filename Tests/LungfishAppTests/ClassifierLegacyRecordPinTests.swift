// ClassifierLegacyRecordPinTests.swift - Known defects of today's classifier records, pinned until the lane that fixes each
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, step 4. Each test pins a defect the 2.7 inventory found in
// a record that today's GUI or CLI path writes, driven with fake tools through
// `ClassifierLegacyRuns`, and names the lane whose change flips it. That lane
// changes the pin in the commit that fixes the defect, so the change shows
// against this base (docs/plans/2026-10-11-phase-2-7.md). A pin of the legacy
// GUI route that lane F3 flipped keeps the legacy half until that route goes
// in 2.9 (E14), and adds what the app's route, the CLI route, records.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
import LungfishKitTestSupport
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ClassifierLegacyRecordPinTests: XCTestCase {

    // MARK: - Batch argv

    /// Lane F3 flipped this (E8, E10). The app's Kraken2 batch takes the CLI
    /// route, whose row records one `kraken2 classify --batch` command over
    /// every sample's files, and that command's root record names the command
    /// that ran (lane A8, `Kraken2AnalysisRunToolTests`). Side C of
    /// `ClassifierCLIGUIParityReplayTests` shows it with real tools in K3,
    /// where the row's command replayed gives the same result. The legacy GUI
    /// batch writer stays with the legacy route until 2.9 (E14). Its record
    /// argv is a `/bin/sh -c` script, `set -e` then one line per sample of six
    /// `/bin/test` guards on the database receipt, three through `plutil` and
    /// one through `conda db info`, before that sample's classify command.
    func testKraken2BatchRowRecordsOneBatchCommandWhereTheLegacyRecordHoldsAShellScript() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let batch = try await ClassifierLegacyRuns.kraken2Batch(fixture: fixture)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch.batchRoot))

        XCTAssertEqual(record.argv.count, 3)
        XCTAssertEqual(Array(record.argv.prefix(2)), ["/bin/sh", "-c"])
        let lines = try XCTUnwrap(record.argv.last).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "set -e")
        XCTAssertEqual(lines.count, 1 + batch.configs.count, "one line per sample")
        for (line, config) in zip(lines.dropFirst(), batch.configs) {
            let commands = line.components(separatedBy: "; ")
            XCTAssertEqual(commands.count, 7, line)
            let guards = commands.prefix(6)
            XCTAssertTrue(guards.allSatisfy { $0.hasPrefix("/bin/test ") }, line)
            XCTAssertEqual(guards.filter { $0.contains("/usr/bin/plutil -extract") }.count, 3, line)
            XCTAssertEqual(guards.filter { $0.contains("conda db info") }.count, 1, line)
            XCTAssertEqual(
                try AdvancedCommandLineOptions.parse(try XCTUnwrap(commands.last)),
                [CLICommandIdentity.executableName] + ClassificationCLIInvocationBuilder.build(for: config).arguments,
                "the line ends with the sample's conda classify command"
            )
        }
        XCTAssertEqual(record.exitStatus, 0)

        // The CLI route's row, the app's route since lane F3.
        let project = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: batch.configs, projectURL: project))
        let reporter = RecordingOperationReporter()
        AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: nil, reporter: reporter) { _ in }
        let command = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertFalse(command.contains("\n"), "one command line")
        let routed = try XCTUnwrap(
            try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(RecordedCLICommand.arguments(of: command)))
                as? ClassifyCommand
        )
        XCTAssertTrue(routed.batch)
        XCTAssertEqual(routed.project, project.path)
        XCTAssertEqual(Set(routed.fastqFiles), Set(batch.configs.flatMap { ($0.originalInputFiles ?? $0.inputFiles).map(\.path) }))
    }

    /// Lane F3 flipped this (E8, E10). The app's EsViritu batch takes the CLI
    /// route, whose row records one `esviritu detect --batch` command over
    /// every sample's files with the database and the project, and
    /// `esviritu detect --batch` records that command as its batch root
    /// record's argv (lane A9, the last half below). Side C of
    /// `ClassifierCLIGUIParityReplayTests` shows it with real tools in E3,
    /// where the row's command replayed gives the same result. The legacy GUI
    /// route keeps its batch writer until 2.9 (E14). Its EsViritu batch
    /// record's argv folds every sample's inputs into one `esviritu detect
    /// --input` named after the first sample, with no database, output folder
    /// or threads, a command that reproduces nothing, and its batch row
    /// records no command at all (`cli-parity-gap` `esviritu-batch`).
    func testEsVirituBatchRowRecordsOneBatchCommandWhereTheLegacyRecordFoldsTheInputs() async throws {
        let root = try TestTempDirectory.make(prefix: "esviritu-batch-argv-pin")
        defer { TestTempDirectory.cleanup(root) }
        let esviritu = try ClassifierLegacyRuns.StandInEsVirituConda(root: root)
        let batch = try await ClassifierLegacyRuns.esVirituBatch(root: root, esviritu: esviritu)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch.batchRoot))

        let folded = EsVirituCLIInvocationBuilder.esVirituBatchCLIArguments(for: batch.configs)
        XCTAssertEqual(record.argv, [CLICommandIdentity.executableName, "esviritu", "detect"] + folded)
        XCTAssertEqual(
            folded,
            ["--input"] + batch.configs.flatMap { $0.inputFiles.map(\.path) } + ["--sample", "SampleA"]
        )
        for flag in ["--db", "--output", "--threads", "--read-format"] {
            XCTAssertFalse(record.argv.contains(flag), "\(flag) is not recorded")
        }
        XCTAssertEqual(record.exitStatus, 0)

        let reporter = RecordingOperationReporter()
        AppDelegate.beginEsVirituBatchOperation(configs: batch.configs, routeContext: nil, reporter: reporter) { _ in }
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertNil(reporter.items.first?.cliCommand)

        // The CLI route's row, the app's route since lane F3.
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(configs: batch.configs, projectURL: project))
        let routeReporter = RecordingOperationReporter()
        AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: nil, reporter: routeReporter) { _ in }
        let routed = try XCTUnwrap(
            try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(
                RecordedCLICommand.arguments(of: XCTUnwrap(routeReporter.items.first?.cliCommand))
            )) as? EsVirituCommand.DetectSubcommand
        )
        XCTAssertTrue(routed.batch)
        XCTAssertEqual(Set(routed.inputFiles), Set(batch.configs.flatMap { $0.inputFiles.map(\.path) }))
        XCTAssertEqual(routed.databasePath, esviritu.databaseURL.path)
        XCTAssertEqual(routed.project, project.path)
        XCTAssertNil(routed.sampleName, "the batch names each sample by its files")

        let cliOutput = root.appendingPathComponent("cli-batch", isDirectory: true)
        let inputPaths = batch.configs.flatMap { $0.inputFiles.map(\.path) }
        let command = try EsVirituCommand.DetectSubcommand.parse(
            ["detect", "--input"] + inputPaths
                + ["--batch", "--db", esviritu.databaseURL.path, "--output", cliOutput.path, "--threads", "2", "--quiet"]
        )
        try await command.execute(
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { nil }
        )
        let cliRecord = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: cliOutput))
        XCTAssertEqual(Array(cliRecord.argv.prefix(3)), ["lungfish-cli", "esviritu", "detect"])
        for argument in ["--batch", "--db", "--output", "--threads"] + inputPaths {
            XCTAssertTrue(cliRecord.argv.contains(argument), "\(argument) is recorded in \(cliRecord.argv)")
        }
        XCTAssertEqual(cliRecord.status, .completed)
    }

    // MARK: - EsViritu lineage

    /// Lane F3 flipped this (D5, E10). The app's EsViritu launch takes the CLI
    /// route, which hands `esviritu detect` the bundle itself, and the command
    /// records the bundle, the command that materialized it, and the bundle's
    /// manifest and payload with their checksums (lane A9, the last half
    /// below). Side C of `ClassifierCLIGUIParityReplayTests` shows it with
    /// real tools in E1. The legacy GUI route keeps its own resolution until
    /// 2.9 (E14), which resolves an unplanned virtual bundle without recording
    /// where its file came from. Its record names only the materialized
    /// scratch file, which the launch deletes after the run, and no
    /// `originalInputs`.
    func testGUIEsVirituRouteHandsTheCommandTheBundleWhereTheLegacyRecordHasNoLineage() async throws {
        let root = try TestTempDirectory.make(prefix: "esviritu-lineage-pin")
        defer { TestTempDirectory.cleanup(root) }
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let esviritu = try ClassifierLegacyRuns.StandInEsVirituConda(root: root.appendingPathComponent("tools", isDirectory: true))
        let bundle = fixtures.subsetOfSingle
        let sample = try XCTUnwrap(MetagenomicsSampleGrouper.group([bundle]).first)
        let plan = await EsVirituSampleReadPlan.planned(for: sample)
        XCTAssertFalse(plan.plansReadSet, "the wizard plans nothing for this sample")
        var config = EsVirituConfig(
            inputFiles: sample.inputFiles,
            isPairedEnd: sample.isPairedEnd,
            sampleName: "sample",
            outputDirectory: root.appendingPathComponent("Analyses/esviritu-batch/sample", isDirectory: true),
            databasePath: esviritu.databaseURL,
            threads: 4,
            readFormat: plan.format,
            inputLayout: plan.layout
        )
        config.plansReadSet = plan.plansReadSet

        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let gui = try await ClassifierLaunchReference.esVirituResolved(config, tempDirectory: scratch, materializer: fixtures.materializer)
        XCTAssertNil(gui.originalInputFiles)
        _ = try await EsVirituPipeline(condaManager: esviritu.condaManager).detect(config: gui)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: gui.outputDirectory))
        XCTAssertNil(record.options.explicit["originalInputs"])
        XCTAssertNil(record.options.explicit["inputMaterializationCommands"])
        let step = try XCTUnwrap(record.steps.first { $0.toolName == "EsViritu" })
        let scratchPath = scratch.resolvingSymlinksInPath().path + "/"
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        XCTAssertTrue(step.inputs.contains { resolved($0.path).hasPrefix(scratchPath) }, "the step reads the scratch file")
        XCTAssertFalse(step.inputs.contains { $0.path.contains(bundle.lastPathComponent) }, "the step names no bundle")

        // The CLI route, the app's route since lane F3, names the bundle in the command it runs.
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(
            configs: [config], projectURL: root.appendingPathComponent("Project.lungfish", isDirectory: true)
        ))
        let routed = try XCTUnwrap(
            try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(launch.arguments)) as? EsVirituCommand.DetectSubcommand
        )
        XCTAssertEqual(routed.inputFiles, [bundle.path], "the route hands the command the bundle, not a scratch file")

        let cliResolved = try await EsVirituCommand.DetectSubcommand.resolveExecutionInputs(
            for: [bundle],
            materializationDirectory: root.appendingPathComponent("cli-inputs", isDirectory: true),
            materializer: fixtures.materializer
        )
        var cli = config
        cli.inputFiles = cliResolved.executionInputURLs
        cli.recordInputLineage(cliResolved)
        XCTAssertEqual(cli.originalInputFiles, [bundle.standardizedFileURL])
        XCTAssertEqual(EsVirituPipeline.inputLineageParameters(for: cli)["originalInputs"], .array([.file(bundle.standardizedFileURL)]))

        let cliOutput = root.appendingPathComponent("cli-run", isDirectory: true)
        let command = try EsVirituCommand.DetectSubcommand.parse([
            "detect", "--input", bundle.path, "--sample", "sample", "--read-format", plan.format.rawValue,
            "--db", esviritu.databaseURL.path, "--output", cliOutput.path, "--threads", "4", "--quiet",
        ])
        try await command.execute(
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: fixtures.materializer,
            installedDatabase: { nil }
        )
        let cliRecord = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: cliOutput))
        XCTAssertEqual(cliRecord.options.explicit["originalInputs"], .array([.file(bundle.standardizedFileURL)]))
        guard case .array(let commands)? = cliRecord.options.explicit["inputMaterializationCommands"] else {
            return XCTFail("the record holds the commands that materialized its inputs")
        }
        XCTAssertTrue(
            commands.contains {
                guard case .string(let text) = $0 else { return false }
                return text.hasPrefix("\(CLICommandIdentity.executableName) fastq materialize ")
                    && text.contains(bundle.standardizedFileURL.path)
            },
            "the fastq materialize command of the bundle: \(commands)"
        )
        for name in ["derived.manifest.json", "read-ids.txt"] {
            let path = resolved(bundle.appendingPathComponent(name).path)
            let file = cliRecord.files.first { resolved($0.path) == path }
            XCTAssertNotNil(file, "files names the bundle's \(name): \(cliRecord.files.map(\.path))")
            XCTAssertNotNil(file?.checksumSHA256, "\(name) has a SHA-256")
        }
    }

    // MARK: - conda classify wrapper

    /// Lane A8 flipped this (D7, D8, E12). The command the Operations panel
    /// records names no `--preset`. At the base the wrapper record said the
    /// run used the balanced preset beside the thresholds it ran with, and
    /// the pipeline record it replaced listed other defaults, confidence 0
    /// and two minimum hit groups. The root record the executor writes names
    /// no preset and holds one defaults table, the command's own, and it
    /// replaces the pipeline record, so the result holds one table.
    func testRootRecordNamesNoPresetNobodyGaveAndHoldsTheCommandsDefaults() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        var config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        config.confidence = 0.5
        config.minimumHitGroups = 3
        let arguments = try ClassifierLegacyRuns.recordedClassifyArguments(for: config)
        XCTAssertFalse(arguments.contains("--preset"))
        let run = try await ClassifierLegacyRuns.condaClassify(
            arguments: arguments, databasePath: config.databasePath, condaManager: fixture.condaManager
        )

        let wrapper = run.wrapperEnvelope.options
        let balanced = ClassificationConfig.Preset.balanced.parameters
        for (name, options) in [("explicit", wrapper.explicit), ("defaults", wrapper.defaults), ("resolved", wrapper.resolvedDefaults)] {
            XCTAssertNil(options["preset"], "the \(name) options name no preset nobody gave (E12)")
        }
        XCTAssertEqual(wrapper.explicit["confidence"], .number(0.5))
        XCTAssertEqual(wrapper.explicit["minimumHitGroups"], .integer(3))
        XCTAssertEqual(wrapper.defaults, Kraken2RunRecordOptions.commandDefaults, "one table, the command's own (D8)")
        XCTAssertEqual(wrapper.defaults["confidence"], .number(balanced.confidence))
        XCTAssertEqual(wrapper.defaults["minimumHitGroups"], .integer(balanced.minimumHitGroups))

        // The pipeline still writes its own table, which side A's GUI record keeps until 2.9. The
        // root record replaces that record in the folder.
        let pipeline = try XCTUnwrap(run.pipelineEnvelope).options
        XCTAssertEqual(pipeline.defaults["confidence"], .number(0))
        XCTAssertEqual(pipeline.defaults["minimumHitGroups"], .integer(2))
        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: run.outputDirectory)?.workflowName, "lungfish.classify")
    }

    /// Lane A8 flipped this (D6, E13). The pipeline record of a sample that
    /// mixes pairs and merged reads holds its read-set plan with the fragment
    /// counts in its legacy home, the explicit options. At the base the
    /// `conda classify` wrapper record that replaced it held none. The root
    /// record holds the plan in its one home, the resolved options.
    /// The wizard's config is recorded without Bracken, the command's default,
    /// because the stand-in kraken2 that counts fragments runs no Bracken.
    func testRootRecordKeepsTheReadSetPlanInTheResolvedOptions() async throws {
        let root = try TestTempDirectory.make(prefix: "wrapper-read-set-plan-pin")
        defer { TestTempDirectory.cleanup(root) }
        let kraken2 = try ClassifierLegacyRuns.StandInKraken2Conda(root: root)
        let databasePath = kraken2.databaseURL
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("read-sets", isDirectory: true))
        let sample = try XCTUnwrap(MetagenomicsSampleGrouper.group([fixtures.mergeDerivative]).first)
        // The wizard's config (`ClassificationWizardSheet.makeProfileConfig`) with the classify goal.
        let readPlan = await ClassificationSampleReadPlan.planned(for: sample)
        var wizard = ClassificationConfig(
            goal: .classify,
            inputFiles: sample.inputFiles,
            isPairedEnd: readPlan.format == .paired,
            interleavedInput: readPlan.format == .interleaved,
            inputLayout: readPlan.layout,
            databaseName: "FixtureDB",
            databaseVersion: "fixture-v1",
            databasePath: databasePath,
            databaseDigest: "sha256:fixture-db",
            databaseCatalogID: nil,
            databaseInstallationRecipe: nil,
            brackenProfileRequest: nil,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: root.appendingPathComponent("output-merge", isDirectory: true),
            extraArguments: []
        )
        wizard.plansReadSet = readPlan.plansReadSet
        XCTAssertTrue(wizard.plansReadSet)
        let arguments = try ClassifierLegacyRuns.recordedClassifyArguments(for: wizard)
        XCTAssertFalse(arguments.contains("--profile"))
        let run = try await ClassifierLegacyRuns.condaClassify(
            arguments: arguments,
            databasePath: databasePath,
            condaManager: kraken2.condaManager,
            materializer: fixtures.materializer
        )

        guard case .dictionary(let plan)? = run.pipelineEnvelope?.options.explicit["readSetPlan"] else {
            return XCTFail("the pipeline records the read-set plan")
        }
        XCTAssertEqual(plan["pairedFragments"], .integer(1))
        XCTAssertEqual(plan["mergedReads"], .integer(3))
        let recorded = try XCTUnwrap(run.wrapperEnvelope.readSetPlan, "the root record holds the plan")
        XCTAssertEqual(recorded.place, .resolvedDefaults)
        XCTAssertEqual(recorded.fields["pairedFragments"], .integer(1))
        XCTAssertEqual(recorded.fields["mergedReads"], .integer(3))
        XCTAssertNil(run.wrapperEnvelope.options.explicit["readSetPlan"])
        XCTAssertNil(run.wrapperEnvelope.options.defaults["readSetPlan"])
    }
}
