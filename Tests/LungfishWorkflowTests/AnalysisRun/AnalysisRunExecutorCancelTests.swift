// AnalysisRunExecutorCancelTests.swift - A cancel request, and nothing else, ends an analysis run as cancelled
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Task cancellation is the only cancel. The status `cancelled` and exit 125 come from the cancel
/// request, never from how a child ended, and the cancelled path hashes nothing and ends well
/// inside the transport's grace (2.7 A6, E5, SWIFT X2, ARCH objection 1).
@Suite("Analysis run executor cancel")
struct AnalysisRunExecutorCancelTests {
    private static let standInDigest = String(repeating: "c", count: 64)

    @Test("A cancel during a unit records cancelled with exit 125 and reuses the digests already taken")
    func cancelDuringAUnit() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .waitForCancel(digest: Self.standInDigest))]
        let request = fixture.request()

        let run = Task { [tool] in await AnalysisRunExecutor.unsigned.execute(tool, request, events: recorder.events) }
        #expect(await probe.waitUntilStarted())
        let cancelledAt = ContinuousClock.now
        run.cancel()
        let report = await run.value
        let settling = ContinuousClock.now - cancelledAt

        #expect(settling < .seconds(5))
        #expect(report.status == .cancelled)
        #expect(report.exitCode == 125)
        #expect(report.message == "\(tool.identity.displayName) was cancelled.")
        #expect(probe.phases == ["plan", "run s1"])

        let folder = try #require(report.analysisDirectory)
        #expect(AnalysisRunRecord.load(from: folder)?.outcome == .cancelled)
        #expect(try AnalysesFolder.listAnalyses(in: fixture.project).isEmpty)

        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .cancelled)
        #expect(record.exitStatus == 125)
        #expect(record.argv == request.commandLine)
        #expect(record.stderr == report.message)
        // The descriptor the unit recorded is kept as it was taken, never hashed again.
        #expect(record.files.contains { $0.checksumSHA256 == Self.standInDigest && $0.fileSize == 16 })
        // The partial output, which cannot even be read, is not hashed or listed.
        #expect(!record.files.contains { $0.path.hasSuffix(".partial.kraken") })
        #expect(recorder.snapshot.last?.event == .failed(message: report.message, detail: nil))
    }

    @Test("A cancel between units stops before the next unit")
    func cancelBetweenUnits() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.layout = .batchRoot
        tool.units = [
            AnalysisRunPlannedUnit(label: "s1", value: .cancelRunThen(nil)),
            AnalysisRunPlannedUnit(label: "s2", value: .complete),
        ]
        let request = fixture.request(groupsSamples: true)

        let report = await Task { [tool] in await AnalysisRunExecutor.unsigned.execute(tool, request, events: .discarding) }.value

        #expect(probe.phases == ["plan", "run s1"])
        #expect(report.status == .cancelled)
        #expect(report.exitCode == 125)
        let folder = try #require(report.analysisDirectory)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("s2").path))
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .cancelled)
        // The unit that completed before the cancel keeps its step and outputs.
        #expect(record.steps.map(\.toolName) == ["fake-classifier"])
    }

    @Test("A child ended by a signal is a failure without a cancel request and a cancel with one")
    func signalledChildFollowsTheCancelRequest() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let signalled = "kraken2 was terminated by signal 15"

        var failing = FakeAnalysisRunTool(probe: FakeToolProbe())
        failing.units = [AnalysisRunPlannedUnit(label: "s1", value: .fail(signalled))]
        let failed = await AnalysisRunExecutor.unsigned.execute(failing, fixture.request(), events: .discarding)
        #expect(failed.status == .failed)
        #expect(failed.exitCode == 64)
        #expect(failed.message == signalled)

        var cancelling = FakeAnalysisRunTool(probe: FakeToolProbe())
        cancelling.units = [AnalysisRunPlannedUnit(label: "s1", value: .cancelRunThen(signalled))]
        let request = fixture.request()
        let cancelled = await Task { [cancelling] in await AnalysisRunExecutor.unsigned.execute(cancelling, request, events: .discarding) }.value
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.exitCode == 125)
        #expect(try fixture.record(at: cancelled.recordURL).status == .cancelled)
    }

    @Test("A cancel during the plan leaves no folder")
    func cancelDuringThePlan() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        for throwsAfterCancel in [true, false] {
            var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
            tool.planCancels = throwsAfterCancel ? .cancelAndThrow : .cancelAndReturn
            let request = fixture.request()

            let report = await Task { [tool] in await AnalysisRunExecutor.unsigned.execute(tool, request, events: recorder.events) }.value

            #expect(report.status == .cancelled)
            #expect(report.exitCode == 125)
            #expect(report.analysisDirectory == nil)
            #expect(report.recordURL == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("Analyses").path))
        #expect(recorder.names == ["start", "failed", "start", "failed"])
    }

    @Test("A cancel during the finalize drops what it wrote from the record")
    func cancelDuringTheFinalize() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let bundle = fixture.project.appendingPathComponent("Reads/s1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.finalizeCancels = true
        tool.sourceBundle = bundle
        let request = fixture.request()

        let report = await Task { [tool] in await AnalysisRunExecutor.unsigned.execute(tool, request, events: .discarding) }.value

        #expect(probe.phases == ["plan", "run s1", "finalize"])
        #expect(report.status == .cancelled)
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .cancelled)
        #expect(!record.files.contains { $0.path.hasSuffix("summary.tsv") })
        #expect(!record.steps.contains { $0.toolName == "fake-index" })
        #expect(AnalysisRunRecord.load(from: try #require(report.analysisDirectory))?.outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent(AnalysisManifest.filename).path))
    }

    @Test("A cancel stops a unit's tool process and leaves none running")
    func cancelStopsTheToolProcess() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .runProcessUntilCancelled)]
        let request = fixture.request()

        let run = Task { [tool] in await AnalysisRunExecutor.unsigned.execute(tool, request, events: .discarding) }
        #expect(await probe.waitUntilStarted())
        let pid = try #require(probe.launchedProcess)
        run.cancel()
        let report = await run.value

        #expect(report.status == .cancelled)
        #expect(report.exitCode == 125)
        #expect(try fixture.record(at: report.recordURL).status == .cancelled)
        #expect(await Self.processEnds(pid))
    }

    /// Whether `pid` is gone within 30 seconds, checked every 50 ms.
    private static func processEnds(_ pid: Int32) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
