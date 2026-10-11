// ProvenanceRunBuilderStatusTests.swift - The builder's status input for failed and cancelled records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// `ProvenanceRunBuilder.complete` takes a status. A failed or cancelled record skips the checks a
/// successful record must pass, a completed one keeps them, and no status keeps the status the
/// builder derived before (ARCH objection 8, 2.7 A6).
@Suite("Provenance run builder status")
struct ProvenanceRunBuilderStatusTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let endedAt = startedAt.addingTimeInterval(3)
    private static let workflowName = "lungfish.fixture"

    /// A builder with no argv, no output and no runtime identity, so only the status rules are in play.
    private static func bareBuilder() -> ProvenanceRunBuilder {
        ProvenanceRunBuilder(
            workflowName: workflowName,
            workflowVersion: "fixture-version",
            toolName: "lungfish-cli",
            toolVersion: "fixture-version"
        )
    }

    private static func nestedRun(status: RunStatus) -> WorkflowRun {
        WorkflowRun(
            name: workflowName,
            startTime: startedAt,
            endTime: endedAt,
            status: status,
            appVersion: "Lungfish fixture",
            hostOS: "macOS fixture",
            runtime: WorkflowRuntime(appVersion: "Lungfish fixture", hostOS: "macOS fixture", user: nil)
        )
    }

    @Test("A failed record holds what the run has, without argv, output or runtime")
    func failedRecordSkipsTheResultChecks() throws {
        let envelope = try Self.bareBuilder().complete(
            exitStatus: 64,
            status: .failed,
            stderr: "The database is missing.",
            startedAt: Self.startedAt,
            endedAt: Self.endedAt
        )

        #expect(envelope.status == .failed)
        #expect(envelope.exitStatus == 64)
        #expect(envelope.stderr == "The database is missing.")
        #expect(envelope.outputs.isEmpty)
    }

    @Test("A cancelled record whose last step exited 0 stays cancelled")
    func cancelledRecordWithExitZeroStaysCancelled() throws {
        let builder = Self.bareBuilder().argv(["lungfish-cli", "fixture", "run"])

        let envelope = try builder.complete(
            exitStatus: 0,
            status: .cancelled,
            startedAt: Self.startedAt,
            endedAt: Self.endedAt
        )

        #expect(envelope.status == .cancelled)
        #expect(envelope.exitStatus == 0)
        // Without a status the same record claims a result and must name an output, as before.
        #expect(throws: ProvenanceBuilderError.missingOutput(Self.workflowName)) {
            try builder.complete(exitStatus: 0, startedAt: Self.startedAt, endedAt: Self.endedAt)
        }
    }

    @Test("A cancelled record with exit 125 writes and reads back cancelled")
    func cancelledRecordRoundTripsThroughTheWriter() throws {
        let directory = try TestTempDirectory.make(prefix: "builder-status")
        defer { TestTempDirectory.cleanup(directory) }
        let envelope = try Self.bareBuilder()
            .argv(["lungfish-cli", "fixture", "run"])
            .complete(
                exitStatus: 125,
                status: .cancelled,
                stderr: "Cancelled.",
                startedAt: Self.startedAt,
                endedAt: Self.endedAt
            )

        let recordURL = try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
        let decoded = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: recordURL))

        #expect(decoded.status == .cancelled)
        #expect(decoded.exitStatus == 125)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        #expect(object?["status"] as? String == "cancelled")
    }

    @Test("A completed status keeps the checks of a successful record")
    func completedStatusKeepsTheResultChecks() throws {
        #expect(throws: ProvenanceBuilderError.missingArgv(Self.workflowName)) {
            try Self.bareBuilder().complete(
                exitStatus: 0,
                status: .completed,
                startedAt: Self.startedAt,
                endedAt: Self.endedAt
            )
        }

        let directory = try TestTempDirectory.make(prefix: "builder-status")
        defer { TestTempDirectory.cleanup(directory) }
        let outputURL = directory.appendingPathComponent("result.tsv")
        try Data("sample\tvalue\n".utf8).write(to: outputURL)
        let envelope = try Self.bareBuilder()
            .argv(["lungfish-cli", "fixture", "run"])
            .runtime(.fixture())
            .output(outputURL)
            .complete(exitStatus: 0, status: .completed, startedAt: Self.startedAt, endedAt: Self.endedAt)
        #expect(envelope.status == .completed)
    }

    @Test("A completed status with a non-zero exit status is refused")
    func completedStatusWithNonZeroExitIsRefused() {
        #expect(throws: ProvenanceBuilderError.statusContradictsExitStatus(Self.workflowName)) {
            try Self.bareBuilder().complete(
                exitStatus: 64,
                status: .completed,
                startedAt: Self.startedAt,
                endedAt: Self.endedAt
            )
        }
        #expect(
            ProvenanceBuilderError.statusContradictsExitStatus(Self.workflowName)
                .errorDescription?.contains(Self.workflowName) == true
        )
    }

    @Test("A running status is refused, because a record is written once its run has ended")
    func runningStatusIsRefused() {
        for exitStatus in [0, 1] {
            #expect(throws: ProvenanceBuilderError.statusIsRunning(Self.workflowName)) {
                try Self.bareBuilder().complete(
                    exitStatus: exitStatus,
                    status: .running,
                    startedAt: Self.startedAt,
                    endedAt: Self.endedAt
                )
            }
        }
        #expect(
            ProvenanceBuilderError.statusIsRunning(Self.workflowName)
                .errorDescription?.contains(Self.workflowName) == true
        )
    }

    @Test("No status keeps the status derived from the exit status or the nested run")
    func noStatusKeepsTheDerivedStatus() throws {
        let failed = try Self.bareBuilder().complete(
            exitStatus: 3,
            startedAt: Self.startedAt,
            endedAt: Self.endedAt
        )
        #expect(failed.status == .failed)

        let nested = try Self.bareBuilder().complete(
            exitStatus: 1,
            startedAt: Self.startedAt,
            endedAt: Self.endedAt,
            legacyWorkflowRun: Self.nestedRun(status: .cancelled)
        )
        #expect(nested.status == .cancelled)
    }

    @Test("A given status replaces the status of a nested run")
    func givenStatusReplacesTheNestedRunStatus() throws {
        let envelope = try Self.bareBuilder().complete(
            exitStatus: 1,
            status: .failed,
            startedAt: Self.startedAt,
            endedAt: Self.endedAt,
            legacyWorkflowRun: Self.nestedRun(status: .completed)
        )

        #expect(envelope.status == .failed)
    }

    @Test("Every status keeps the time range check")
    func everyStatusKeepsTheTimeRangeCheck() {
        for status in [RunStatus.failed, .cancelled, .completed] {
            #expect(throws: ProvenanceBuilderError.invalidTimeRange(Self.workflowName)) {
                try Self.bareBuilder().complete(
                    exitStatus: status == .completed ? 0 : 1,
                    status: status,
                    startedAt: Self.endedAt,
                    endedAt: Self.startedAt
                )
            }
        }
    }
}
