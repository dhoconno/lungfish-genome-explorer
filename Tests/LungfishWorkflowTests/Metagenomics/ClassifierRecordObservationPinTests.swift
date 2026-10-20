// ClassifierRecordObservationPinTests.swift - The Kraken2, Bracken and EsViritu records before their launches are observed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane S36 M1, item 1 (QA 1). Pins taken at the base, before any classifier launch bound a ToolProcess
// observer. Each record is captured masked (`ClassifierRecordCapture`), so the binding of item 2 shows up here as
// exactly the `observation` key it adds to the kraken2, bracken and EsViritu steps and nothing else. The probe that
// picks Bracken's CLI dialect runs and is no step, and no record writes a peak memory (Phase 2.7 decision P4).

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

final class ClassifierRecordObservationPinTests: XCTestCase {

    // MARK: - The masked captures

    /// `ClassificationPipeline.classify`, a Kraken2 run with no profile.
    func testTheMaskedCaptureOfAKraken2Record() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        ClassifierRecordCapture.assertLines(try ClassifierRecordCapture.lines(in: config.outputDirectory), equal: [
            "record: argv,createdAt,durableReplayArgv,exitStatus,files,id,options,output,outputs,reproducibleCommand,runtimeIdentity,schemaVersion,signatures,status,steps,tool,toolName,toolVersion,wallTimeSeconds,workflowName,workflowVersion",
            "kraken2 exit=0: argv,completedAt,dependsOn,durableReplayArgv,exitStatus,id,inputs,observation,outputs,reproducibleCommand,resolvedOptions,runtimeIdentity,startedAt,stderr,toolName,toolVersion,wallTimeSeconds",
            "lungfish-kraken2-index exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
            "gzip exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
            "Lungfish Kraken2 Output Removal exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
            "Lungfish Classification Result Sidecar exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
        ])
    }

    /// `ClassificationPipeline.profile`, the run the Kraken2 wizard asks for, whose record holds the Bracken step.
    func testTheMaskedCaptureOfABrackenRecord() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)

        ClassifierRecordCapture.assertLines(try ClassifierRecordCapture.lines(in: config.outputDirectory), equal: [
            "record: argv,createdAt,durableReplayArgv,exitStatus,files,id,options,output,outputs,reproducibleCommand,runtimeIdentity,schemaVersion,signatures,status,steps,tool,toolName,toolVersion,wallTimeSeconds,workflowName,workflowVersion",
            "kraken2 exit=0: argv,completedAt,dependsOn,durableReplayArgv,exitStatus,id,inputs,observation,outputs,reproducibleCommand,resolvedOptions,runtimeIdentity,startedAt,stderr,toolName,toolVersion,wallTimeSeconds",
            "Lungfish Bracken Preflight exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,runtimeIdentity,startedAt,toolName,toolVersion,wallTimeSeconds",
            "bracken exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,managedToolID,observation,outputs,reproducibleCommand,resolvedOptions,runtimeIdentity,startedAt,stderr,toolName,toolVersion,toolVersionEvidence,wallTimeSeconds",
            "lungfish-kraken2-index exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
            "gzip exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
            "Lungfish Kraken2 Output Removal exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
            "Lungfish Classification Result Sidecar exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
        ])
    }

    /// `EsVirituPipeline.detect` on one sample file.
    func testTheMaskedCaptureOfAnEsVirituRecord() async throws {
        let run = try StandInEsVirituRun()
        defer { run.remove() }

        _ = try await EsVirituPipeline(condaManager: run.condaManager).detect(config: run.config)

        ClassifierRecordCapture.assertLines(try ClassifierRecordCapture.lines(in: run.config.outputDirectory), equal: [
            "record: argv,createdAt,exitStatus,files,githubReleaseVersion,id,options,output,outputs,reproducibleCommand,runtimeIdentity,schemaVersion,signatures,status,steps,tool,toolName,toolVersion,wallTimeSeconds,workflowName,workflowVersion",
            "EsViritu exit=0: argv,completedAt,dependsOn,exitStatus,githubReleaseVersion,id,inputs,observation,outputs,reproducibleCommand,resolvedOptions,startedAt,stderr,toolName,toolVersion,wallTimeSeconds",
            "Lungfish EsViritu Result Sidecar exit=0: argv,completedAt,dependsOn,exitStatus,id,inputs,outputs,reproducibleCommand,resolvedOptions,startedAt,toolName,toolVersion,wallTimeSeconds",
        ])
    }

    /// 2.13 lane 13.15 pin (BIO-13.15-legacy item 2). The build's EsViritu release stays the `githubReleaseVersion` of
    /// the EsViritu step, of that step in the legacy view and of the record, wherever the options file it.
    func testTheEsVirituReleaseVersionStaysOnTheStepTheLegacyStepAndTheRecord() async throws {
        let run = try StandInEsVirituRun()
        defer { run.remove() }

        _ = try await EsVirituPipeline(condaManager: run.condaManager).detect(config: run.config)

        let release = EsVirituPipeline.esVirituGithubReleaseVersion
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.config.outputDirectory))
        XCTAssertEqual(envelope.steps.first { $0.toolName == "EsViritu" }?.githubReleaseVersion, release)
        let legacy = try XCTUnwrap(ProvenanceRecorder.load(from: run.config.outputDirectory))
        XCTAssertEqual(legacy.steps.first { $0.toolName == "EsViritu" }?.githubReleaseVersion, release)
        XCTAssertEqual(envelope.githubReleaseVersion, release)
    }

    // MARK: - The probe and the peak memory

    /// The `bracken --help` probe that picks the CLI dialect runs before the profiling launch and never becomes a step.
    func testTheBrackenHelpProbeRunsBeforeTheProfileAndIsNoStep() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)

        let invocations = try fixture.toolInvocations(named: "bracken")
        let profiling = try fixture.brackenProfileInvocations()
        XCTAssertEqual(profiling.count, 1, "one profiling launch")
        let probe = try XCTUnwrap(invocations.firstIndex(of: "bracken --help"), "the dialect probe ran")
        let launch = try XCTUnwrap(invocations.firstIndex(of: try XCTUnwrap(profiling.first)))
        XCTAssertLessThan(probe, launch, "the probe runs before the profiling launch")
        let steps = try ClassifierRecordCapture.steps(in: config.outputDirectory)
        XCTAssertEqual(steps.filter { $0["toolName"] as? String == "bracken" }.count, 1, "one bracken step")
        for step in steps {
            let argv = step["argv"] as? [String] ?? []
            XCTAssertFalse(argv.contains("--help"), "\(step["toolName"] ?? "?") is the probe")
        }
    }

    /// Phase 2.7 decision P4. Peak memory goes into the ToolProcess observation only, and no record writes it until
    /// a golden normalizer rule for it is approved.
    func testNoClassifierRecordWritesAPeakMemory() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let profile = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: profile)
        let esviritu = try StandInEsVirituRun()
        defer { esviritu.remove() }
        _ = try await EsVirituPipeline(condaManager: esviritu.condaManager).detect(config: esviritu.config)

        for directory in [profile.outputDirectory, esviritu.config.outputDirectory] {
            let names = try ClassifierRecordCapture.allKeyNames(in: directory)
            XCTAssertTrue(names.contains("steps"), "the record was read")
            for name in ["peakMemoryBytes", "observedPeakMemoryBytes", "peakMemory"] {
                XCTAssertFalse(names.contains(name), "\(directory.lastPathComponent) writes \(name)")
            }
        }
    }
}
