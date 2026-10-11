// ProvenanceRecorderRetentionTests.swift - What ProvenanceRecorder keeps in memory and what it lets go
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.7 lane S3, decision P11 as amended by the Swift and bioinformatics experts. A run leaves the
/// unsaved runs at `save`, the last 16 saved runs stay readable, and past 64 unsaved runs beginning a
/// run evicts only runs that completed and were never saved, never a run still recording. Every test
/// uses a recorder of its own, because tests share `ProvenanceRecorder.shared`.
final class ProvenanceRecorderRetentionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "recorder-retention")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(directory)
    }

    func testASavedRunStaysReadableWhileItIsAmongTheLastSixteenSaved() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        var saved: [UUID] = []
        for index in 0..<ProvenanceRecorder.savedRunRetention {
            saved.append(try await savedRun(index, in: recorder))
        }
        let readable = await held(saved, in: recorder)
        XCTAssertEqual(readable, saved, "each of the last 16 saved runs stays readable")
        let envelope = await recorder.canonicalEnvelope(for: saved[0])
        XCTAssertEqual(envelope?.id, saved[0])

        // A run saved again becomes the newest, so the next save lets the second run go.
        try await recorder.save(runID: saved[0], to: directory.appendingPathComponent("again", isDirectory: true))
        let newest = try await savedRun(99, in: recorder)
        let kept = await held(saved + [newest], in: recorder)
        XCTAssertEqual(kept, [saved[0]] + saved.dropFirst(2) + [newest], "the oldest saved run leaves past 16")
        let released = await recorder.canonicalEnvelope(for: saved[1])
        XCTAssertNil(released)
        do {
            try await recorder.save(runID: saved[1], to: directory)
            XCTFail("a run the recorder let go cannot be saved")
        } catch ProvenanceError.runNotFound(let runID) {
            XCTAssertEqual(runID, saved[1])
        }
    }

    func testASavedRunStillTakesAStepAndACompletion() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = try await savedRun(1, in: recorder)
        await recorder.completeRun(runID, status: .failed)
        let stepID = await recorder.recordStep(
            runID: runID, toolName: "late", toolVersion: "1.0", command: ["late"],
            inputs: [], outputs: [], exitCode: 2, wallTime: 0
        )
        XCTAssertNotNil(stepID)
        let run = await recorder.getRun(runID)
        XCTAssertEqual(run?.status, .failed)
        XCTAssertEqual(run?.steps.map(\.toolName), ["tool", "late"])
    }

    func testPastTheCapBeginningARunEvictsTheRunCompletedLongestAgoAndNoRunStillRecording() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        // Three runs still recording, begun before all the others.
        var recording: [UUID] = []
        for index in 0..<3 {
            recording.append(await recorder.beginRun(name: "Recording \(index)"))
        }
        // The rest of the cap, completed and never saved, in the reverse of the order they began.
        var completed: [UUID] = []
        for index in 0..<(ProvenanceRecorder.unsavedRunCap - recording.count) {
            completed.append(await recorder.beginRun(name: "Completed \(index)"))
        }
        for runID in completed.reversed() {
            await recorder.completeRun(runID, status: .failed)
        }
        let atTheCap = await held(recording + completed, in: recorder)
        XCTAssertEqual(atTheCap, recording + completed, "nothing is evicted at the cap")

        // One run past the cap evicts the run completed first, which began last.
        let extra = await recorder.beginRun(name: "Extra")
        let afterOne = await held(recording + completed + [extra], in: recorder)
        XCTAssertEqual(afterOne, recording + completed.dropLast() + [extra])

        // Completing a run that began early does not make it older than runs completed before it.
        await recorder.completeRun(recording[0], status: .cancelled)
        let another = await recorder.beginRun(name: "Another")
        let afterTwo = await held(recording + completed + [extra, another], in: recorder)
        XCTAssertEqual(afterTwo, recording + completed.dropLast(2) + [extra, another])
    }

    func testARunStillRecordingIsNeverEvictedEvenPastTheCap() async throws {
        let recorder = ProvenanceRecorder(signingProvider: nil)
        var recording: [UUID] = []
        for index in 0..<(ProvenanceRecorder.unsavedRunCap + 6) {
            recording.append(await recorder.beginRun(name: "Recording \(index)"))
        }
        let allKept = await held(recording, in: recorder)
        XCTAssertEqual(allKept, recording, "a run still recording stays past the cap")

        // Only a run that completed can go, and it goes when the next run begins.
        await recorder.completeRun(recording[10], status: .completed)
        let next = await recorder.beginRun(name: "Next")
        let afterNext = await held(recording + [next], in: recorder)
        XCTAssertEqual(afterNext, recording.filter { $0 != recording[10] } + [next])
    }

    func testTheEnvelopeAccessorsGiveTheRecordSaveWritesAndListEveryRunMostRecentFirst() async throws {
        let time = SteppedTimeSource(startingAt: ProvenanceRecorderSavePinScenarios.start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let first = await time.override {
            await recorder.beginRun(name: "First", parameters: ["limit": .integer(5)])
        }
        time.advance(by: 1)
        await recorder.recordStep(
            runID: first, toolName: "tool", toolVersion: "1.0", command: ["tool", "--limit", "5"],
            inputs: [], outputs: [FileRecord(path: "/fixture/out.txt", sha256: "ab", sizeBytes: 2, role: .output)],
            exitCode: 0, wallTime: 1
        )
        await recorder.completeRun(first, status: .completed)
        let target = directory.appendingPathComponent("first", isDirectory: true)
        try await recorder.save(runID: first, to: target)
        let written = try Data(contentsOf: target.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let accessed = await recorder.canonicalEnvelope(for: first)
        let envelope = try XCTUnwrap(accessed, "the run just saved is still readable")
        XCTAssertEqual(
            String(decoding: try ProvenanceJSON.encoder.encode(envelope), as: UTF8.self),
            String(decoding: written, as: UTF8.self),
            "the accessor gives the bytes the save wrote"
        )

        time.advance(by: 1)
        let second = await time.override { await recorder.beginRun(name: "Second") }
        let runs = await recorder.allRuns()
        let envelopes = await recorder.canonicalEnvelopes()
        XCTAssertEqual(runs.map(\.id), [second, first], "an unsaved run and a saved one, most recent first")
        XCTAssertEqual(envelopes.map(\.id), [second, first])
        XCTAssertEqual(envelopes.first { $0.status == .completed }?.id, first, "the app's export fallback")
    }

    // MARK: - Helpers

    /// Begins, records one step in, completes and saves a run, and returns its id.
    private func savedRun(_ index: Int, in recorder: ProvenanceRecorder) async throws -> UUID {
        let runID = await recorder.beginRun(name: "Saved \(index)")
        await recorder.recordStep(
            runID: runID, toolName: "tool", toolVersion: "1.0", command: ["tool", "\(index)"],
            inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: directory.appendingPathComponent("run-\(index)", isDirectory: true))
        return runID
    }

    /// The runs of `runIDs` the recorder still holds, in the order given.
    private func held(_ runIDs: [UUID], in recorder: ProvenanceRecorder) async -> [UUID] {
        var result: [UUID] = []
        for runID in runIDs {
            if await recorder.getRun(runID) != nil {
                result.append(runID)
            }
        }
        return result
    }
}
