// TaxTriageParityLiveConformanceTests+Cancel.swift - X6 on the real engine, side C cancelled once a container runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32 M2, with 2.10 T2, QA 4 and SWIFT 7. Side C, the routed `taxtriage run --project` through
// the built lungfish-cli, is cancelled as a CLI route's Cancel does it: SIGTERM to the CLI alone through
// CLIRunCancellation (`CLIClassifierRunner.signalsCommandFirst`, U30 W2), so its own container cleanup runs, with
// `CLIProcessLauncher.operationGrace` (6 s) before SIGKILL to its group and tree, the grace CLIClassifierRunner
// gives. The harness cancels once the stand-in records a launch, which a real engine never does, so this file
// starts the CLI itself and cancels once a container of the run runs, found by its mounts below the side root or
// the work folder the launch names, as NextflowContainerCleanupLiveConformanceTests finds them. The command must
// exit 125 inside the grace, its record must say cancelled with exit 125 and no result, and `docker ps -a` must
// hold no container of the run when it exits.
//
// The status, the record and the container lists go to `<LUNGFISH_PARITY_EVIDENCE>/X6/`. The run with every core
// busy (SWIFT 7) is the same test under `busy_cores.py` with an evidence folder of its own, and its `status.txt`
// shows the cores and the load. Side A's cancel stays with the stand-in class, since the flip moves side C. The
// stand-in test cancels at the stand-in's launch and checks the same end without Docker.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// What one cancel of side C did.
struct TaxTriageParityCancel {
    /// How the launcher saw the end, without the output.
    let outcome: String
    let exitStatus: Int32?
    let stderr: String
    /// From the launch to the engine's start, the first running container or the stand-in's launch.
    let startedAfter: Duration
    /// From the cancel to the command's exit.
    let exitedAfter: Duration
    let analysisFolder: URL?
    let record: ProvenanceEnvelope?
    let resultWritten: Bool
    /// The run's containers that ran at the cancel, or the stand-in's launch.
    let atTheCancel: [String]
    let runningAtTheExit: [String]
    /// The run's containers in `docker ps -a` when the command exited.
    let leftAtTheExit: [String]
    /// The same up to 10 s after the cancel, for the record.
    let leftLater: [String]
    let leftLaterAfter: Duration
}

/// Whether the command of a cancel case has returned, set from its own task.
final class TaxTriageParityRunEnded: Sendable {
    private let marked = Mutex(false)

    func mark() {
        marked.withLock { $0 = true }
    }

    var isMarked: Bool { marked.withLock { $0 } }
}

extension TaxTriageParityLiveConformanceTests {
    // MARK: - X6 on the real engine (M2)

    func testX6CancelOnceTheRealEngineStarted() async throws {
        let run = try LiveNextflowRun.begin()
        let root = run.directory.appendingPathComponent("X6/\(TaxTriageParitySide.c.folderName)", isDirectory: true)
        var workFolders = [root]
        defer { let end = run.teardown(engineWorkFolders: workFolders); print("[live-nextflow] X6 teardown removed \(end.removedContainerIDs.map { String($0.prefix(12)) })"); XCTAssertEqual(end.problems, []) }
        let evidence = try TaxTriageParityEvidence.requireFolder()
        try TaxTriageParityEvidence.prepare(.x6, in: evidence, baseline: nil)
        let engine = try await Self.liveEngine(run)
        let cancel = try await cancelRoutedSide(
            .x6,
            root: root,
            engine: engine,
            engineStarted: { ended in try await Self.runningContainers(of: run, under: root, until: ended) },
            containers: { includingStopped in
                try run.ownedContainers(
                    includingStopped: includingStopped,
                    engineWorkFolders: [root] + Self.engineWorkFolders(under: root)
                ).map(\.id)
            }
        )
        workFolders += Self.engineWorkFolders(under: root)
        let folder = try TaxTriageParityCancelEvidence.write(cancel, root: root, to: evidence, notes: ["live root \(run.root.path), key \(run.key)"])
        print("[live-nextflow] X6 evidence in \(folder.path)")
        assertCancel(cancel, containersChecked: true)
    }

    // MARK: - X6 on the stand-in

    /// The cancel of the live test on the stand-in engine, at the stand-in's launch, with no container to check.
    func testTheX6CancelAndItsEvidenceOnTheStandIn() async throws {
        let scratch = try TestTempDirectory.make(prefix: "taxtriage-parity-live")
        defer { TestTempDirectory.cleanup(scratch) }
        let caseRoot = scratch.appendingPathComponent(TaxTriageParityCase.x6.rawValue, isDirectory: true)
        let engine = try standInEngine(in: caseRoot, for: .x6)
        let standIn = try XCTUnwrap(engine.standIn)
        let root = caseRoot.appendingPathComponent(TaxTriageParitySide.c.folderName, isDirectory: true)
        let cancel = try await cancelRoutedSide(
            .x6,
            root: root,
            engine: engine,
            engineStarted: { _ in
                guard let launch = await standIn.waitForLaunch(0, timeout: .seconds(30)) else {
                    throw LiveNextflowError.misconfigured("The stand-in engine recorded no launch within 30 s.")
                }
                return ["stand-in launch \(launch.folder.lastPathComponent)"]
            },
            containers: { _ in [] }
        )
        let evidence = scratch.appendingPathComponent("evidence", isDirectory: true)
        let folder = try TaxTriageParityCancelEvidence.write(cancel, root: root, to: evidence, notes: ["stand-in"])
        assertCancel(cancel, containersChecked: false)

        let status = try String(contentsOf: folder.appendingPathComponent("status.txt"), encoding: .utf8)
        XCTAssertTrue(status.contains("exit 125"), status)
        let records = TaxTriageParityComparison.Rules.relativeFiles(under: folder.appendingPathComponent("records", isDirectory: true))
        XCTAssertTrue(records.contains { $0.hasSuffix("/.lungfish-provenance.json") }, "the cancelled record is saved raw, \(records)")
        XCTAssertThrowsError(try TaxTriageParityCancelEvidence.write(cancel, root: root, to: evidence, notes: []))
    }

    // MARK: - The cancel

    /// Runs side C of `parityCase` in `root` with the built lungfish-cli, cancels it once `engineStarted` returns and
    /// reads how it ended. `containers` lists the run's containers, running only or in `docker ps -a`.
    func cancelRoutedSide(
        _ parityCase: TaxTriageParityCase,
        root: URL,
        engine: TaxTriageParityEngine,
        engineStarted: (TaxTriageParityRunEnded) async throws -> [String],
        containers: (Bool) throws -> [String]
    ) async throws -> TaxTriageParityCancel {
        _ = try parityCase.makeProject(in: root)
        let words = try TaxTriageParityHarness(testCase: self, cliBinary: cliBinary).routedCommand(parityCase, root: root, engine: engine)
        var spec = CLIProcessLauncher.spec(
            executableURL: cliBinary,
            arguments: words,
            standardOutput: .captured,
            terminationGracePeriod: CLIProcessLauncher.operationGrace
        )
        // The runner signals the TaxTriage command first (U30 W2), so the live cancel runs the termination the app runs.
        spec.signalsProcessFirst = CLIClassifierRunner.signalsCommandFirst(.taxTriage)
        spec.environment.merge(engine.cliEnvironment) { _, engineValue in engineValue }
        // 12.01 Fix 3 (B6). The child gets the shell's variables whatever the launcher inherits.
        spec.environment.merge(TaxTriageParityHarness.inheritedShellVariables) { _, shellValue in shellValue }
        let launcherSpec = spec
        let cancellation = CLIRunCancellation()
        let ended = TaxTriageParityRunEnded()
        let clock = ContinuousClock()
        let launchedAt = clock.now
        let process = Task {
            defer { ended.mark() }
            return await CLIProcessLauncher.run(launcherSpec, cancellation: cancellation)
        }
        let atTheCancel: [String]
        do {
            atTheCancel = try await engineStarted(ended)
        } catch {
            cancellation.cancel()
            _ = await process.value
            throw error
        }
        let cancelledAt = clock.now
        cancellation.cancel()
        let outcome = await process.value
        let exitedAfter = clock.now - cancelledAt
        let runningAtTheExit = try containers(false)
        let leftAtTheExit = try containers(true)
        var leftLater = leftAtTheExit
        while !leftLater.isEmpty, clock.now - cancelledAt < .seconds(10) {
            try await Task.sleep(for: .milliseconds(500))
            leftLater = try containers(true)
        }
        let analyses = root.appendingPathComponent("\(ClassifierParityFixtures.projectName)/Analyses", isDirectory: true)
        let folder = TaxTriageParityHarness.visibleFolders(in: analyses).first.map { analyses.appendingPathComponent($0, isDirectory: true) }
        var exit: CLIProcessExit?
        var described: String
        switch outcome {
        case .exited(let value): exit = value; described = "exited"
        case .cancelled(let value?): exit = value; described = "cancelled"
        case .cancelled(nil): described = "cancelled before the launch"
        case .launchFailed(let reason): described = "launch failed, \(reason)"
        }
        return TaxTriageParityCancel(
            outcome: described,
            exitStatus: exit?.status,
            stderr: exit?.failureDetail ?? "",
            startedAfter: cancelledAt - launchedAt,
            exitedAfter: exitedAfter,
            analysisFolder: folder,
            record: folder.flatMap { try? ProvenanceEnvelopeReader.load(from: $0) },
            resultWritten: folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("taxtriage-result.json").path) } ?? false,
            atTheCancel: atTheCancel,
            runningAtTheExit: runningAtTheExit,
            leftAtTheExit: leftAtTheExit,
            leftLater: leftLater,
            leftLaterAfter: clock.now - cancelledAt
        )
    }

    /// The end 2.10 T2 asks of a cancel once the engine runs.
    func assertCancel(_ cancel: TaxTriageParityCancel, containersChecked: Bool) {
        XCTAssertEqual(cancel.exitStatus, 125, "the cancelled taxtriage run exits 125, \(cancel.outcome): \(cancel.stderr.suffix(2000))")
        XCTAssertLessThanOrEqual(cancel.exitedAfter, CLIProcessLauncher.operationGrace, "the command ends inside operationGrace")
        XCTAssertEqual(cancel.record?.status, .cancelled, "the record says cancelled")
        XCTAssertEqual(cancel.record?.exitStatus, 125, "the record says exit 125")
        XCTAssertFalse(cancel.resultWritten, "a cancelled run writes no result")
        guard containersChecked else { return }
        XCTAssertFalse(cancel.atTheCancel.isEmpty, "a container of the run ran at the cancel")
        XCTAssertEqual(cancel.runningAtTheExit, [], "N5, no container of the run runs once the command has exited")
        XCTAssertEqual(cancel.leftAtTheExit, [], "docker ps -a holds no container of the run when the command exits")
    }

    /// The ids of the run's running containers, once one runs below `root` or the work folder a launch below it
    /// names, waiting up to 5 minutes or until the command ends.
    static func runningContainers(of run: LiveNextflowRun, under root: URL, until ended: TaxTriageParityRunEnded) async throws -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline, !ended.isMarked {
            let running = try run.ownedContainers(includingStopped: false, engineWorkFolders: [root] + engineWorkFolders(under: root))
            if !running.isEmpty { return running.map(\.id) }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LiveNextflowError.misconfigured("No container of the run ran below \(root.path) within 300 s, or the command ended first.")
    }
}

/// The evidence of one cancel, `<LUNGFISH_PARITY_EVIDENCE>/X6/`: `status.txt`, `containers.txt`, `stderr.txt` and the
/// raw bytes of every record below the side root in `records/`. A folder that exists is never written again.
enum TaxTriageParityCancelEvidence {
    static func write(_ cancel: TaxTriageParityCancel, root: URL, to evidence: URL, notes: [String]) throws -> URL {
        let folder = evidence.appendingPathComponent(TaxTriageParityCase.x6.rawValue, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw LiveNextflowError.misconfigured("\(folder.path) holds the evidence of another run. Name a fresh \(TaxTriageParityEvidence.folderVariable).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func seconds(_ duration: Duration) -> String {
            String(format: "%.3f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        }
        let record = cancel.record.map { "\($0.status), exit \($0.exitStatus.map(String.init) ?? "none")" } ?? "none"
        try TaxTriageParityEvidence.text(
            ["case X6, side C, written \(ISO8601DateFormatter().string(from: Date()))"] + notes + [
                TaxTriageParityEvidence.machineLine(),
                "outcome \(cancel.outcome), exit \(cancel.exitStatus.map(String.init) ?? "none") \(seconds(cancel.exitedAfter)) after the cancel, grace \(seconds(CLIProcessLauncher.operationGrace))",
                "the engine started \(seconds(cancel.startedAfter)) after the launch",
                "record \(record), analysis \(cancel.analysisFolder?.lastPathComponent ?? "none"), result written \(cancel.resultWritten)",
            ],
            to: folder.appendingPathComponent("status.txt")
        )
        try TaxTriageParityEvidence.text(
            [
                "running at the cancel: \(cancel.atTheCancel)",
                "running at the exit: \(cancel.runningAtTheExit)",
                "in docker ps -a at the exit: \(cancel.leftAtTheExit)",
                "in docker ps -a \(seconds(cancel.leftLaterAfter)) after the cancel: \(cancel.leftLater)",
            ],
            to: folder.appendingPathComponent("containers.txt")
        )
        try TaxTriageParityEvidence.text([cancel.stderr], to: folder.appendingPathComponent("stderr.txt"))
        for relative in TaxTriageParityComparison.Rules.recordPaths(under: root) {
            try TaxTriageParityEvidence.copy(root.appendingPathComponent(relative), to: folder.appendingPathComponent("records/\(relative)"))
        }
        return folder
    }
}
