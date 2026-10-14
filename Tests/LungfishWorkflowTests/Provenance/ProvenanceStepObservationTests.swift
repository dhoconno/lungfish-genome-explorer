// ProvenanceStepObservationTests.swift - The observation key a declared step's launch writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.7 lane S3 (scope row B2, decisions P1, P3 and P4). The recorder takes the ToolProcess
/// observation of a declared step's launch and writes it as the step's optional `observation` key, at
/// schema version 2. No producer declares a step yet, so no record and no golden holds the key.
final class ProvenanceRecorderObservationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "recorder-observation")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(directory)
    }

    private static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// A `/bin/sh -c` launch standing in for a tool, in a hermetic environment.
    private static func standIn(_ script: String, change: ToolProcessEnvironmentChange? = nil) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["PATH": systemPath],
            terminationGracePeriod: .milliseconds(200),
            drainGracePeriod: .seconds(2),
            label: "stand-in",
            environmentChange: change,
            identityHint: "stand-in"
        )
    }

    func testADeclaredStepRecordsItsLaunchAndAProbeOutsideTheScopeRecordsNothing() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Observed run")
        let declared = await recorder.declareStep(runID: runID)
        let declaration = try XCTUnwrap(declared)
        let change = ToolProcessEnvironmentChange(
            base: .hermetic,
            set: ["PATH": Self.systemPath, "MAMBA_NO_BANNER": "1", "HOME": "/fixture/home"],
            pathPrefix: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"],
            sanitizing: PortablePath.Context(projectURL: nil)
        )

        // A version probe through the same adapter, before and after the bound scope.
        let probe = try await ToolProcess.run(Self.standIn("echo 'stand-in 1.0'"))
        let result = try await ToolProcessObservation.$observer.withValue(declaration.observer) {
            try await ToolProcess.run(Self.standIn("echo working >&2; exit 3", change: change))
        }
        _ = try await ToolProcess.run(Self.standIn("echo 'stand-in 1.0'"))
        XCTAssertEqual(probe.status, 0)
        let observed = declaration.observations
        XCTAssertEqual(observed.count, 1, "only the declared launch is observed")
        XCTAssertEqual(observed.first?.stages.first?.argv.last, "echo working >&2; exit 3")
        XCTAssertNotNil(observed.first?.stages.first?.observedPeakMemoryBytes, "the hook carries a peak memory")

        let stepID = await recorder.recordStep(
            runID: runID, toolName: "stand-in", toolVersion: "1.0", command: ["stand-in", "--run"],
            inputs: [], outputs: [], exitCode: result.status, wallTime: 0.1, stderr: "working\n"
        )
        let recorded = await recorder.recordObservation(of: declaration, forStep: stepID)
        let observation = try XCTUnwrap(recorded)
        XCTAssertEqual(observation.termination, .exited(code: 3))
        XCTAssertNil(observation.stop)
        XCTAssertEqual(observation.outputComplete, true)
        XCTAssertEqual(observation.stage, .init(index: 0, count: 1))
        let environment = try XCTUnwrap(observation.environment)
        XCTAssertEqual(environment.base, .hermetic)
        XCTAssertEqual(environment.changed, ["HOME", "MAMBA_NO_BANNER", "PATH"])
        XCTAssertEqual(environment.values, ["MAMBA_NO_BANNER": "1"], "HOME and PATH keep their names only")
        XCTAssertEqual(environment.pathPrefix, change.pathPrefix)

        await recorder.completeRun(runID, status: .failed)
        try await recorder.save(runID: runID, to: directory)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let record = try ProvenanceEnvelopeReader.decodeCanonical(bytes)
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.observation, observation, "the key reads back")
        XCTAssertEqual(step.argv, ["stand-in", "--run"], "the observation never replaces the step's argv")
        XCTAssertEqual(step.exitStatus, 3)
        XCTAssertNil(step.peakMemoryBytes, "peak memory from the observation is never written (P4)")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        let key = try XCTUnwrap(steps.first?["observation"] as? [String: Any])
        XCTAssertEqual(Set(key.keys), ["termination", "outputComplete", "environment", "stage"])
        let termination = try XCTUnwrap(key["termination"] as? [String: Any])
        XCTAssertEqual(termination["kind"] as? String, "exited")
        XCTAssertEqual(termination["code"] as? Int, 3)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("emory"), "no memory key anywhere")
    }

    func testALaunchOutsideTheDeclaredScopeLeavesTheStepWithoutAnObservation() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Unobserved run")
        let declared = await recorder.declareStep(runID: runID)
        let declaration = try XCTUnwrap(declared)
        let result = try await ToolProcess.run(Self.standIn("exit 0"))
        XCTAssertTrue(declaration.observations.isEmpty)

        let stepID = await recorder.recordStep(
            runID: runID, toolName: "stand-in", toolVersion: "1.0", command: ["stand-in"],
            inputs: [], outputs: [], exitCode: result.status, wallTime: 0.1
        )
        let recorded = await recorder.recordObservation(of: declaration, forStep: stepID)
        XCTAssertNil(recorded, "a declared step that observed nothing records no observation")
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: directory)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"observation\""))
    }

    func testAScopeThatCoveredTwoLaunchesRecordsNoObservation() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Two launches")
        let declared = await recorder.declareStep(runID: runID)
        let declaration = try XCTUnwrap(declared)
        let result = try await ToolProcessObservation.$observer.withValue(declaration.observer) {
            _ = try await ToolProcess.run(Self.standIn("echo 'stand-in 1.0'"))
            return try await ToolProcess.run(Self.standIn("exit 0"))
        }
        XCTAssertEqual(declaration.observations.count, 2)
        let stepID = await recorder.recordStep(
            runID: runID, toolName: "stand-in", toolVersion: "1.0", command: ["stand-in"],
            inputs: [], outputs: [], exitCode: result.status, wallTime: 0.1
        )
        let recorded = await recorder.recordObservation(of: declaration, forStep: stepID)
        XCTAssertNil(recorded, "a probe inside the scope could be taken for the step, so neither is recorded")
        let run = await recorder.canonicalEnvelope(for: runID)
        XCTAssertNil(try XCTUnwrap(run).steps.first?.observation)
    }

    func testNoStepIsDeclaredForARunTheRecorderDoesNotHold() async {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let declared = await recorder.declareStep(runID: UUID())
        XCTAssertNil(declared)
    }
}

/// The `observation` key on its own, from the hook's stage entry to its bytes and back.
final class ProvenanceStepObservationCodingTests: XCTestCase {
    private func stage(
        _ ending: ToolProcessRunObservation.Ending,
        stop: ToolProcessStop? = nil,
        outputComplete: Bool? = true,
        change: ToolProcessEnvironmentChange? = nil,
        index: Int = 0,
        count: Int = 1
    ) -> ToolProcessRunObservation.Stage {
        ToolProcessRunObservation.Stage(
            index: index,
            stageCount: count,
            label: "tool",
            argv: ["/fixture/tool", "--run"],
            workingDirectory: nil,
            ending: ending,
            startedAt: nil,
            wallTime: nil,
            stop: stop,
            outputComplete: outputComplete,
            failedOnItsOwn: false,
            stderr: nil,
            environmentChange: change,
            identityHint: "tool",
            observedPeakMemoryBytes: 123_456_789
        )
    }

    private func object(_ observation: ProvenanceStepObservation) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ProvenanceJSON.encoder.encode(observation)) as? [String: Any])
    }

    func testASignaledStageStoppedByTheIdleLimitKeepsTheShapeOfTheKey() throws {
        let change = ToolProcessEnvironmentChange(
            base: .hermetic,
            set: ["HOME": "/fixture/home", "MAMBA_NO_BANNER": "1", "PATH": "/usr/bin:/bin", "TMPDIR": "/fixture/tmp"],
            pathPrefix: ["/usr/bin", "/bin"],
            sanitizing: PortablePath.Context(projectURL: nil)
        )
        let observation = ProvenanceStepObservation(stage(
            .terminated(.signaled(signal: 15)), stop: .timedOut(.idle(.seconds(600))), outputComplete: false, change: change
        ))
        let key = try object(observation)
        XCTAssertEqual(Set(key.keys), ["termination", "stop", "outputComplete", "environment", "stage"])
        let termination = try XCTUnwrap(key["termination"] as? [String: Any])
        XCTAssertEqual(termination["kind"] as? String, "signaled")
        XCTAssertEqual(termination["signal"] as? Int, 15)
        let stop = try XCTUnwrap(key["stop"] as? [String: Any])
        XCTAssertEqual(stop["reason"] as? String, "timedOut")
        XCTAssertEqual(stop["limit"] as? String, "idle")
        XCTAssertEqual(stop["seconds"] as? Double, 600)
        XCTAssertEqual(key["outputComplete"] as? Bool, false)
        let environment = try XCTUnwrap(key["environment"] as? [String: Any])
        XCTAssertEqual(Set(environment.keys), ["base", "changed", "values", "pathPrefix"], "no unset for a hermetic base")
        XCTAssertEqual(environment["base"] as? String, "hermetic")
        XCTAssertEqual(environment["changed"] as? [String], ["HOME", "MAMBA_NO_BANNER", "PATH", "TMPDIR"])
        XCTAssertEqual(environment["values"] as? [String: String], ["MAMBA_NO_BANNER": "1"])
        XCTAssertEqual(environment["pathPrefix"] as? [String], change.pathPrefix)
        let stageKey = try XCTUnwrap(key["stage"] as? [String: Any])
        XCTAssertEqual(stageKey["index"] as? Int, 0)
        XCTAssertEqual(stageKey["count"] as? Int, 1)
    }

    func testEveryEndingAndStopRoundTrips() throws {
        let inherited = ToolProcessEnvironmentChange(
            base: .inherited,
            set: ["NXF_ANSI_LOG": "false", "LANG": "C"],
            unset: ["DYLD_INSERT_LIBRARIES"],
            sanitizing: PortablePath.Context(projectURL: nil)
        )
        let stages: [ToolProcessRunObservation.Stage] = [
            stage(.terminated(.exited(code: 0))),
            stage(.terminated(.signaled(signal: 9)), stop: .cancelled, change: inherited),
            stage(.statusLost),
            stage(.launchFailed(reason: "posix_spawn of /fixture/tool failed."), outputComplete: nil, index: 1, count: 3),
            stage(.notLaunched, stop: .pipelineStageFailed(stage: 1), outputComplete: nil, index: 2, count: 3),
            stage(.terminated(.signaled(signal: 15)), stop: .timedOut(.wallClock(.milliseconds(1_500)))),
        ]
        for stage in stages {
            let observation = ProvenanceStepObservation(stage)
            let decoded = try ProvenanceJSON.decoder.decode(
                ProvenanceStepObservation.self,
                from: ProvenanceJSON.encoder.encode(observation)
            )
            XCTAssertEqual(decoded, observation)
        }
        let unset = try XCTUnwrap(try object(ProvenanceStepObservation(stages[1]))["environment"] as? [String: Any])
        XCTAssertEqual(unset["unset"] as? [String], ["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(unset["changed"] as? [String], ["LANG", "NXF_ANSI_LOG"])
        XCTAssertEqual(unset["values"] as? [String: String], ["NXF_ANSI_LOG": "false"], "LANG is off the allowlist")
        XCTAssertEqual(ProvenanceStepObservation(stages[3]).termination, .launchFailed(reason: "posix_spawn of /fixture/tool failed."))
        XCTAssertEqual(ProvenanceStepObservation(stages[5]).stop, .timedOut(limit: .wallClock, seconds: 1.5))
    }

    func testAStreamedOrUnlaunchedStageWritesNoOutputCompleteness() throws {
        let streamed = try object(ProvenanceStepObservation(stage(.terminated(.exited(code: 0)), outputComplete: nil)))
        XCTAssertNil(streamed["outputComplete"], "Not recorded for a stage that streamed its stdout (P3)")
        XCTAssertNil(streamed["environment"], "no environment when the adapter said nothing")
        XCTAssertNil(streamed["stop"])
        let unlaunched = try object(ProvenanceStepObservation(stage(.notLaunched, outputComplete: nil)))
        XCTAssertNil(unlaunched["outputComplete"])
    }

    func testThePeakMemoryOfTheHookIsNeverWritten() throws {
        let bytes = try ProvenanceJSON.encoder.encode(ProvenanceStepObservation(stage(.terminated(.exited(code: 0)))))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("123456789"), "decision P4")
        XCTAssertFalse(text.contains("emory"))
    }

    func testAStepReadsWithAnObservationItCannotReadAndWritesNoKeyWithoutOne() throws {
        let unreadable = """
        {"id": "1D0F3D9E-6A3F-4C55-9D3E-3D0B9C7E2A10", "toolName": "tool", "toolVersion": "1.0",
         "argv": ["tool"], "exitStatus": 0,
         "observation": {"termination": {"kind": "frozenInTime"}, "stage": {"index": 0, "count": 1}}}
        """
        let step = try ProvenanceJSON.decoder.decode(ProvenanceStep.self, from: Data(unreadable.utf8))
        XCTAssertNil(step.observation, "an observation in a shape this build does not know reads as not observed")
        XCTAssertEqual(step.argv, ["tool"])
        XCTAssertEqual(step.exitStatus, 0)

        let plain = String(decoding: try ProvenanceJSON.encoder.encode(ProvenanceStep(toolName: "tool")), as: UTF8.self)
        XCTAssertFalse(plain.contains("observation"))

        let observed = ProvenanceStep(toolName: "tool").with {
            $0.observation = ProvenanceStepObservation(stage(.terminated(.exited(code: 0))))
        }
        let reread = try ProvenanceJSON.decoder.decode(ProvenanceStep.self, from: ProvenanceJSON.encoder.encode(observed))
        XCTAssertEqual(reread, observed)
    }

    /// Phase 2.10 S8. A launch that replaced the inherited PATH says so in the key, because its `pathPrefix`
    /// then holds the whole PATH the child got and would read as a prefix. A launch that extended the
    /// inherited PATH, set none, or started from an empty environment writes no such key.
    func testAReplacedPathIsWrittenAsPathReplacedAndOnlyThen() throws {
        let context = PortablePath.Context(projectURL: nil)
        let inherited = "/opt/inherited/bin:/usr/bin"
        func environment(of change: ToolProcessEnvironmentChange) throws -> [String: Any] {
            let key = try object(ProvenanceStepObservation(stage(.terminated(.exited(code: 0)), change: change)))
            return try XCTUnwrap(key["environment"] as? [String: Any])
        }

        let replaced = try environment(of: NativeToolRunner.environmentChange(
            overriding: ["PATH": "/fixture/only/bin:/usr/bin"], inheritedPath: inherited, sanitizing: context
        ))
        XCTAssertEqual(replaced["pathReplaced"] as? Bool, true, "the whole PATH was replaced, so pathPrefix is not a prefix")
        XCTAssertEqual((replaced["pathPrefix"] as? [String])?.count, 2, "pathPrefix keeps every entry of the new PATH")

        let extended = try environment(of: NativeToolRunner.environmentChange(
            overriding: ["PATH": "/fixture/first/bin:\(inherited)"], inheritedPath: inherited, sanitizing: context
        ))
        XCTAssertNil(extended["pathReplaced"], "a PATH that ends with the inherited one replaces nothing")
        XCTAssertEqual((extended["pathPrefix"] as? [String])?.count, 1)

        let untouched = try environment(of: NativeToolRunner.environmentChange(
            overriding: ["LANG": "C"], inheritedPath: inherited, sanitizing: context
        ))
        XCTAssertNil(untouched["pathReplaced"], "a launch that sets no PATH replaces none")

        let hermetic = try environment(of: ToolProcessEnvironmentChange(
            base: .hermetic, set: ["PATH": "/usr/bin:/bin"], pathPrefix: ["/usr/bin", "/bin"], sanitizing: context
        ))
        XCTAssertNil(hermetic["pathReplaced"], "an empty environment has no inherited PATH to replace")
    }

    /// Phase 2.10 S8. A record written before the key reads as not replaced, and a replaced PATH round trips.
    func testAnOlderEnvironmentReadsAsNotReplacedAndAReplacedPathRoundTrips() throws {
        typealias Environment = ProvenanceStepObservation.Environment
        let older = #"{"base": "inherited", "changed": ["PATH"], "pathPrefix": ["/usr/bin"]}"#
        let decoded = try ProvenanceJSON.decoder.decode(Environment.self, from: Data(older.utf8))
        XCTAssertFalse(decoded.pathReplaced)
        XCTAssertEqual(decoded.pathPrefix, ["/usr/bin"])

        let change = ToolProcessEnvironmentChange(
            base: .inherited, set: ["PATH": "/opt/only/bin"], pathPrefix: ["/opt/only/bin"], pathReplaced: true,
            sanitizing: PortablePath.Context(projectURL: nil)
        )
        let environment = Environment(change)
        XCTAssertTrue(environment.pathReplaced, "the record reads the flag off the change")
        let bytes = try ProvenanceJSON.encoder.encode(environment)
        XCTAssertEqual(try ProvenanceJSON.decoder.decode(Environment.self, from: bytes), environment)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(written["pathReplaced"] as? Bool, true)
        XCTAssertFalse(String(decoding: try ProvenanceJSON.encoder.encode(decoded), as: UTF8.self).contains("pathReplaced"))
    }
}
