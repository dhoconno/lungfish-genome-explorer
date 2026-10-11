// ClassifierLegacyRecordPinTests.swift - Known defects of today's classifier records, pinned until the lane that fixes each
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, step 4. Each test pins a defect the 2.7 inventory found in
// a record that today's GUI or CLI path writes, driven with fake tools through
// `ClassifierLegacyRuns`, and names the lane whose change flips it. That lane
// changes the pin in the commit that fixes the defect, so the change shows
// against this base (docs/plans/2026-10-11-phase-2-7.md).

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

    /// Lane A8 flips this (E8). The Kraken2 batch record's argv is a
    /// `/bin/sh -c` script, `set -e` then one line per sample of six
    /// `/bin/test` guards on the database receipt, three through `plutil` and
    /// one through `conda db info`, before that sample's `conda classify`
    /// command. No command runs the batch as one.
    func testKraken2BatchRecordArgvIsAShellScriptOfGuardsAndOneClassifyPerSample() async throws {
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
    }

    /// Lane A9 flips this (E8). The EsViritu batch record's argv folds every
    /// sample's inputs into one `esviritu detect --input` named after the
    /// first sample, with no database, output folder or threads, a command
    /// that reproduces nothing. The batch row records no command at all
    /// (`cli-parity-gap` `esviritu-batch`).
    func testEsVirituBatchRecordArgvFoldsEveryInputIntoOneDetect() async throws {
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
    }

    // MARK: - EsViritu lineage

    /// Lane A9 flips this (D5). The legacy GUI EsViritu launch resolves an
    /// unplanned virtual bundle without recording where its file came from.
    /// The record names only the materialized scratch file, which the launch
    /// deletes after the run, and no `originalInputs`. The CLI resolution of
    /// the same sample records the bundle.
    func testGUIEsVirituRecordOfAnUnplannedVirtualBundleHasNoLineage() async throws {
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
        let gui = try await AppDelegate().resolvedEsVirituConfig(config, tempDirectory: scratch, materializer: fixtures.materializer)
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
    }

    // MARK: - conda classify wrapper

    /// Lane A8 flips this (D7, D8, E12). The command the Operations panel
    /// records names no `--preset`, yet the wrapper record says the run used
    /// the balanced preset and lists the balanced thresholds as its defaults,
    /// beside the thresholds it ran with. The pipeline record it replaced
    /// lists other defaults, confidence 0 and two minimum hit groups.
    func testWrapperRecordsABalancedPresetNobodyGaveAndDefaultsThePipelineDoesNotHold() async throws {
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
        XCTAssertNil(wrapper.explicit["preset"])
        XCTAssertEqual(wrapper.defaults["preset"], .string("balanced"))
        XCTAssertEqual(wrapper.resolvedDefaults["preset"], .string("balanced"), "a run made with 0.5 and 3 reads balanced")
        XCTAssertEqual(wrapper.explicit["confidence"], .number(0.5))
        XCTAssertEqual(wrapper.explicit["minimumHitGroups"], .integer(3))
        XCTAssertEqual(wrapper.defaults["confidence"], .number(balanced.confidence))
        XCTAssertEqual(wrapper.defaults["minimumHitGroups"], .integer(balanced.minimumHitGroups))

        let pipeline = try XCTUnwrap(run.pipelineEnvelope).options
        XCTAssertEqual(pipeline.defaults["confidence"], .number(0))
        XCTAssertEqual(pipeline.defaults["minimumHitGroups"], .integer(2))
        XCTAssertNotEqual(pipeline.defaults["confidence"], wrapper.defaults["confidence"], "the two writers disagree")
    }

    /// Lane A8 flips this (D6, E13). The pipeline record of a sample that
    /// mixes pairs and merged reads holds its read-set plan with the fragment
    /// counts. The `conda classify` wrapper record that replaces it holds none.
    /// The wizard's config is recorded without Bracken, the command's default,
    /// because the stand-in kraken2 that counts fragments runs no Bracken.
    func testWrapperDropsThePipelinesReadSetPlan() async throws {
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
        let wrapper = run.wrapperEnvelope.options
        for (name, options) in [("explicit", wrapper.explicit), ("defaults", wrapper.defaults), ("resolved", wrapper.resolvedDefaults)] {
            XCTAssertNil(options["readSetPlan"], "the wrapper's \(name) options hold no plan")
        }
    }
}
