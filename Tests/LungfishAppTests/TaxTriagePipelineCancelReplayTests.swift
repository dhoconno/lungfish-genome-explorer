// TaxTriagePipelineCancelReplayTests.swift - A TaxTriage cancel on the in-process route, on the stand-in engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane S1, decisions T10 to T13 (docs/plans/2026-10-11-phase-2-8.md) and 2.7 E5. The Tools
// menu runs TaxTriage in process, through `TaxTriageSerialBatchRunner` and `TaxTriagePipeline`, and
// its Cancel cancels the task. Each case runs that route on `TaxTriageStandInEngine`, most of them
// in its TERM-trapping mode, where the engine and a heartbeat child it forks trap TERM and go on, so
// only a KILL after a grace ends the tree.
//
// At the base of the lane each defect sat in an `XCTExpectFailure` block, XCTest's known issue.
// The fix made them plain assertions. A cancel stops the whole tree with TERM, then KILL after a
// 4 s grace, before the run returns. It records `cancelled` with exit 125 and no output, and the
// launch scratch goes only once the tree is gone. A cancel during the finish wins, and a serial
// batch stops at its next sample and saves its record as cancelled.
//
// The cases start processes and the GUI case runs on `OperationCenter.shared`, so the class runs
// serially. Its name ends in ReplayTests, which sends it to the integration tier (`REPLAY_SUITES` in
// scripts/full-suite-gate.sh).

import AppKit
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriagePipelineCancelReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-cancel")
    }

    override func tearDown() async throws {
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - The pipeline

    func testACancelStopsTheWholeEngineTreeBeforeTheRunReturns() async throws {
        let engine = try makeEngine(.trapsTermWithHeartbeatChild)
        let config = try makeConfig([("S1", 2)], output: "single")

        let run = Task { try await engine.makePipeline().run(config: config) }
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)
        let childID = try XCTUnwrap(launch.childProcessIdentifier)
        let workFolder = try XCTUnwrap(launch.value(after: "-w"), "the launch names no work folder")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workFolder + "/aa/000001/.command.log"),
            "the engine writes into its work folder before it is marked started"
        )
        let watcher = Self.watchWorkFolder(workFolder, child: childID)

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        run.cancel()
        let outcome = await run.result
        let waited = clock.now - cancelledAt
        let treeRunsAfterTheRun = Self.isRunning(engineID) || Self.isRunning(childID)
        let workWentWhileTheChildRan = await watcher.value
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)
        let step = record?.steps.first { $0.toolName == "TaxTriage" }
        let ended = try engine.launches().first

        // T4, which recorded failed with exit -1.
        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(record?.status, .cancelled, "the record says cancelled, from the request")
        XCTAssertEqual(record?.exitStatus, 125, "a cancel records exit 125, never the signal that ended the engine")
        XCTAssertEqual(step?.exitStatus, 125)
        XCTAssertEqual(step?.outputs.map(\.path) ?? ["no step"], [], "a cancel hashes no partial output")
        // T5, where the engine and its child outlived the run and got no signal.
        XCTAssertFalse(treeRunsAfterTheRun, "no process of the engine tree may outlive the run")
        XCTAssertEqual(Set(ended?.trappedSignals ?? []), ["TERM"], "the engine gets TERM first")
        XCTAssertEqual(Set(ended?.childTrappedSignals ?? []), ["TERM"], "its child gets TERM too")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(3500), "the tree has its 4 s grace before KILL")
        // T5, where the launch scratch went while the engine's child still ran.
        XCTAssertFalse(workWentWhileTheChildRan, "the scratch goes only once the tree is gone")
        XCTAssertLessThan(waited, .seconds(30))
        XCTAssertNil(ended?.exitStatus, "a launch a signal ended, or one still running, records no exit status")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: launch.workingDirectory),
            "the launch scratch is removed once the run returns"
        )
    }

    func testACancelDuringTheFinishWins() async throws {
        let engine = try makeEngine(.completes)
        let config = try makeConfig([("F1", 2)], output: "finish")

        let run = Task {
            try await engine.makePipeline().run(config: config) { _, message in
                // The pipeline says this once the engine has exited 0, so the cancel lands in the finish.
                if message == "Collecting output files..." {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let outcome = await run.result
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)
        let resultFile = config.outputDirectory.appendingPathComponent("taxtriage-result.json")

        XCTAssertEqual(try engine.launches().map(\.exitStatus), [0], "the engine completed")
        // T10, where a cancel during the finish was ignored and the run completed.
        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(record?.status, .cancelled)
        XCTAssertEqual(record?.exitStatus, 125)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultFile.path), "a cancelled run writes no result")
    }

    // MARK: - The serial batch runner

    func testACancelInASerialBatchStopsAtTheNextSampleAndRecordsTheCancel() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let config = try makeConfig([("B1", 2), ("B2", 3)], output: "batch")

        let run = Task { try await engine.makeRunner().run(config: config) }
        let started = await engine.waitForLaunch()
        XCTAssertNotNil(started, "the first sample never launched")
        run.cancel()
        let outcome = await run.result
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)

        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(try engine.launches().count, 1, "the batch stops before its next sample")
        // T9, where the batch run was begun and never completed or saved.
        XCTAssertEqual(record?.status, .cancelled, "the batch records the cancel")
        XCTAssertEqual(record?.steps.map(\.exitStatus) ?? [], [125], "one step, the cancelled sample, exit 125")
        XCTAssertEqual(record?.steps.first?.outputs.count, 0, "a cancel hashes no partial output")
    }

    // MARK: - The Tools menu route

    func testCancellingTheToolsMenuRunSettlesItsRowOnlyOnceTheEngineTreeIsGone() async throws {
        let engine = try makeEngine(.trapsTermWithHeartbeatChild)
        let reads = try writeFASTQ("G1.fastq", records: 3)
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "G1", fastq1: reads)],
            outputDirectory: scratch.appendingPathComponent("replaced-by-the-launch", isDirectory: true),
            kraken2DatabasePath: try makeDatabaseFolder(),
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile
        )

        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = OverlayRecordingViewer()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({ engine.makeRunner() }) {
            delegate.runTaxTriage(
                config: config,
                viewerController: viewer,
                routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil)
            )
        }
        let rowID = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) }?.id, "runTaxTriage started no row")
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)
        let childID = try XCTUnwrap(launch.childProcessIdentifier)

        OperationCenter.shared.cancel(id: rowID)
        let settled = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            OperationCenter.shared.items.first { $0.id == rowID }.map { !$0.state.isActive } ?? true
        }
        let treeRunsWhenTheRowSettles = Self.isRunning(engineID) || Self.isRunning(childID)
        XCTAssertTrue(settled, "the row did not settle in 30 seconds")
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == rowID })
        XCTAssertEqual(item.state, .cancelled, "\(item.displayStateLabel): \(item.detail)")

        let analysis = try XCTUnwrap(
            Self.visibleFolders(in: project.appendingPathComponent("Analyses", isDirectory: true)).onlyElement,
            "the launch must make one analysis folder"
        )
        let record = try ProvenanceEnvelopeReader.load(from: analysis)
        // T4 and T5, where the row settled at once while the tree ran on, and the record said failed.
        XCTAssertFalse(treeRunsWhenTheRowSettles, "the row settles only once the engine tree is gone")
        XCTAssertEqual(record?.status, .cancelled, "the run's record says cancelled")
    }

    // MARK: - Helpers

    /// The engine for one case, stopped in teardown so no stand-in outlives a case that fails.
    private func makeEngine(_ behaviour: TaxTriageStandInEngine.Behaviour) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: scratch.appendingPathComponent("engine", isDirectory: true),
            behaviour: behaviour
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// A stand-in run of one single-end FASTQ per sample into `output` under the scratch folder.
    private func makeConfig(_ samples: [(id: String, records: Int)], output: String) throws -> TaxTriageConfig {
        TaxTriageConfig(
            samples: try samples.map {
                TaxTriageSample(sampleId: $0.id, fastq1: try writeFASTQ("\($0.id).fastq", records: $0.records))
            },
            outputDirectory: scratch.appendingPathComponent(output, isDirectory: true),
            kraken2DatabasePath: try makeDatabaseFolder(),
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile
        )
    }

    /// A FASTQ of `records` four-line records whose names never pair, so no input reads as
    /// interleaved.
    private func writeFASTQ(_ name: String, records: Int) throws -> URL {
        let folder = scratch.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let text = (1...records).map { "@\(stem)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Kraken2 database folder. The stand-in never reads it, but the pipeline checks it exists.
    private func makeDatabaseFolder() throws -> URL {
        let folder = scratch.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Whether `pid` names a process that has not exited. A zombie only waits to be reaped, so it
    /// has exited.
    nonisolated private static func isRunning(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) != SZOMB
    }

    /// Watches the work folder until it is gone, then says whether the child still ran at that
    /// moment. The folder is read before the child, so a child that ended before the folder went
    /// never reads as the defect. Gives up after 60 seconds with false.
    nonisolated private static func watchWorkFolder(_ workFolder: String, child childID: Int32) -> Task<Bool, Never> {
        Task.detached {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            while clock.now < deadline {
                let present = FileManager.default.fileExists(atPath: workFolder)
                let running = Self.isRunning(childID)
                if !present { return running }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
    }

    private static func visibleFolders(in folder: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private extension Array {
    /// The element of a one-element array, else nil.
    var onlyElement: Element? { count == 1 ? first : nil }
}

private extension Result {
    /// The error of a failed result, else nil.
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
