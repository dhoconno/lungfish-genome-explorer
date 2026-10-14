// ClassifierStepObservationTests.swift - The kraken2, Bracken and EsViritu steps carry the observation of their launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane S36 M1, item 2. Each classifier pipeline declares its tool's step before the one launch and passes
// the declaration's observer to `CondaManager.runTool`, which binds it around that launch alone. The step the
// pipeline records for the launch, on success, failure or cancel, gains `observation`. A probe through the same
// adapter (`bracken --help`, a version probe, the micromamba probes) runs outside the binding, so a test observer
// bound around the whole run sees the probes and never a declared launch.

import XCTest
import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

final class ClassifierStepObservationTests: XCTestCase {

    // MARK: - Completed runs

    func testTheKraken2AndBrackenStepsCarryTheObservationOfTheirOwnLaunch() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let ambient = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(ambient.observer) {
            try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)
        }

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.steps.filter { $0.observation != nil }.map(\.toolName), ["kraken2", "bracken"])
        for tool in ["kraken2", "bracken"] {
            let observation = try XCTUnwrap(envelope.steps.first { $0.toolName == tool }?.observation, tool)
            XCTAssertEqual(observation.termination, .exited(code: 0), tool)
            XCTAssertNil(observation.stop, tool)
            XCTAssertEqual(observation.outputComplete, true, tool)
            XCTAssertEqual(observation.stage, .init(index: 0, count: 1), tool)
            assertHermeticCondaEnvironment(observation.environment, of: fixture.condaManager, callerNames: [], tool)
            try assertTheRecordKeepsTheRootSanitized(of: tool, in: config.outputDirectory, manager: fixture.condaManager)
        }
        let stages = ambient.all.flatMap(\.stages)
        XCTAssertTrue(stages.contains { $0.label == "bracken" && $0.argv.last == "--help" }, "the dialect probe")
        XCTAssertTrue(stages.contains { $0.label == "micromamba" }, "a micromamba version probe")
        XCTAssertEqual(
            stages.filter { ["kraken2", "bracken"].contains($0.label) && !Self.isProbe($0.argv) }.map(\.label), [],
            "a declared launch is bound to its own declaration, never to the task's observer"
        )
    }

    func testTheEsVirituStepCarriesTheObservationOfItsLaunch() async throws {
        let run = try StandInEsVirituRun()
        defer { run.remove() }
        let ambient = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(ambient.observer) {
            try await EsVirituPipeline(condaManager: run.condaManager).detect(config: run.config)
        }

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.config.outputDirectory))
        XCTAssertEqual(envelope.steps.filter { $0.observation != nil }.map(\.toolName), ["EsViritu"])
        let observation = try XCTUnwrap(envelope.steps.first { $0.toolName == "EsViritu" }?.observation)
        XCTAssertEqual(observation.termination, .exited(code: 0))
        XCTAssertNil(observation.stop)
        XCTAssertEqual(observation.outputComplete, true)
        XCTAssertEqual(observation.stage, .init(index: 0, count: 1))
        assertHermeticCondaEnvironment(observation.environment, of: run.condaManager, callerNames: ["ESVIRITU_DB"], "EsViritu")
        try assertTheRecordKeepsTheRootSanitized(of: "EsViritu", in: run.config.outputDirectory, manager: run.condaManager)
        let stages = ambient.all.flatMap(\.stages)
        XCTAssertEqual(stages.filter { $0.label == "EsViritu" && !Self.isProbe($0.argv) }.map(\.label), [])
    }

    // MARK: - Failed and cancelled launches

    func testAFailedKraken2KeepsItsObservation() async throws {
        let fixture = try FakeClassificationCondaFixture(krakenBehavior: .nonzero(3))
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)
            XCTFail("kraken2 exited 3")
        } catch ClassificationPipelineError.kraken2Failed(let exitCode, _) {
            XCTAssertEqual(exitCode, 3)
        }

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(step.exitStatus, 3)
        XCTAssertEqual(step.observation?.termination, .exited(code: 3))
        XCTAssertNil(step.observation?.stop)
    }

    func testAFailedBrackenAndABrackenWithoutOutputKeepTheirObservation() async throws {
        let cases: [(FakeClassificationCondaFixture.BrackenBehavior, Int)] = [(.nonzero(2), 2), (.missingOutput, 0)]
        for (behavior, code) in cases {
            let fixture = try FakeClassificationCondaFixture(brackenBehavior: behavior)
            defer { fixture.cleanup() }
            let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)

            _ = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)

            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
            XCTAssertEqual(envelope.steps.filter { $0.observation != nil }.map(\.toolName), ["kraken2", "bracken"])
            let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
            XCTAssertEqual(step.exitStatus, code)
            XCTAssertEqual(step.observation?.termination, .exited(code: code))
        }
    }

    /// SWIFT 7. A cancelled Bracken records its cancelled step with the observation of the launch ToolProcess stopped.
    func testACancelledBrackenKeepsItsObservation() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .waitForCancellation)
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let pipeline = ClassificationPipeline(condaManager: fixture.condaManager)
        let profile = Task { try await pipeline.profile(config: config) }

        let deadline = ContinuousClock.now + .seconds(30)
        while try fixture.brackenProfileInvocations().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(try fixture.brackenProfileInvocations().isEmpty, "Bracken started before the cancel")
        profile.cancel()
        do {
            _ = try await profile.value
            XCTFail("the profile was cancelled")
        } catch is CancellationError {}

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.status, .cancelled)
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertEqual(step.exitStatus, 130)
        let observation = try XCTUnwrap(step.observation, "a cancel keeps its observation")
        XCTAssertEqual(observation.stop, .cancelled)
        XCTAssertEqual(observation.termination, .signaled(signal: Int(SIGTERM)))
        XCTAssertEqual(observation.stage, .init(index: 0, count: 1))
    }

    // MARK: - Helpers

    /// The bytes of the record hold the root prefix as the adapter sanitized it, never the raw scratch path.
    private func assertTheRecordKeepsTheRootSanitized(
        of tool: String,
        in directory: URL,
        manager: CondaManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let step = try XCTUnwrap(try ClassifierRecordCapture.steps(in: directory).first { $0["toolName"] as? String == tool })
        let environment = (step["observation"] as? [String: Any])?["environment"] as? [String: Any]
        XCTAssertEqual(
            (environment?["values"] as? [String: String])?["MAMBA_ROOT_PREFIX"],
            PortablePath.sanitize(path: manager.rootPrefix.path, context: manager.environmentChangeContext),
            tool, file: file, line: line
        )
    }

    /// A probe through `runTool`, whose last argument asks for help or a version.
    private static func isProbe(_ argv: [String]) -> Bool {
        ["--help", "--version", "-v"].contains(argv.last ?? "")
    }

    /// The change `runTool` records for its hermetic environment. Names only, except the root prefix, and the PATH
    /// entries it put first.
    private func assertHermeticCondaEnvironment(
        _ environment: ProvenanceStepObservation.Environment?,
        of manager: CondaManager,
        callerNames: [String],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let environment else {
            return XCTFail("\(message) records no environment", file: file, line: line)
        }
        let parentHasTmpdir = ProcessInfo.processInfo.environment["TMPDIR"] != nil
        let names = ["HOME", "MAMBA_ROOT_PREFIX", "PATH"] + callerNames + (parentHasTmpdir ? ["TMPDIR"] : [])
        XCTAssertEqual(environment.base, .hermetic, message, file: file, line: line)
        XCTAssertEqual(environment.changed, names.sorted(), message, file: file, line: line)
        // The record keeps the sanitized root (`assertTheRecordKeepsTheRootSanitized`), which the reader resolves.
        XCTAssertEqual(environment.values, ["MAMBA_ROOT_PREFIX": manager.rootPrefix.path], message, file: file, line: line)
        XCTAssertEqual(environment.unset, [], message, file: file, line: line)
        XCTAssertEqual(environment.pathPrefix, ["/usr/bin", "/bin", "/usr/sbin", "/sbin"], message, file: file, line: line)
    }
}
