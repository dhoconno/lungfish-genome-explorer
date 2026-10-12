// TaxTriageRunSIGTERMReplayTests.swift - A SIGTERM to `taxtriage run` cancels the pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S11, SWIFT inventory E8. The window's Cancel sends SIGTERM to `lungfish-cli`.
// `taxtriage run` converted no SIGTERM, so the signal ended the CLI (exit 143 in a shell, the R3
// run of lane Q15) before the pipeline's own cancel ran. The run left no `cancelled` record and no
// exit 125. Now the command listens like `workflow run` does, so the signal cancels the task that
// runs `TaxTriagePipeline`, the cancel the Tools menu route has had since Phase 2.8 lane S1.
//
// The check needs a process that may die, so the test runs this test bundle again in a child
// xctest process, which runs `taxtriage run` on `TaxTriageStandInEngine` in process, as the other
// replay classes do. The parent waits until the engine runs, sends the child one SIGTERM and reads
// how the child ended. Since lane A2 runs `taxtriage run` on the analysis run executor, the
// executor's cancel contract records the cancel (S2), so the record is the executor's root record
// under `lungfish.taxtriage.run`, with `cancelled` and 125, written inside the CLI's 6 s grace.
//
// The engine starts processes, so the class runs serially. Its name ends in ReplayTests, which
// sends it to the integration tier (`REPLAY_SUITES` in scripts/full-suite-gate.sh).

import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageRunSIGTERMReplayTests: XCTestCase {
    private static let childFolderVariable = "LUNGFISH_TAXTRIAGE_SIGTERM_CHILD"

    func testASIGTERMCancelsTheRunAndTheCommandExits125() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let xctest = arguments.first, xctest.hasSuffix("xctest") else {
            throw XCTSkip("Needs to run under xctest to start a child test process")
        }
        let bundle = Bundle(for: Self.self).bundlePath
        let folder = try TestTempDirectory.make(prefix: "taxtriage-sigterm")
        defer { TestTempDirectory.cleanup(folder) }
        let launchedFile = folder.appendingPathComponent("launched")
        // Declared after the folder's cleanup, so it runs first and stops an engine a failed case left.
        defer { Self.stopEngine(launchedFile) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: xctest)
        child.arguments = ["-XCTest", "LungfishAppTests.TaxTriageRunSIGTERMReplayTests/testTaxTriageRunChild", bundle]
        // An IDE run hands this process the variables of its test session.
        // The child is a plain xctest run, so it must not join that session.
        var environment = ProcessInfo.processInfo.environment.filter { key, value in
            !(key.hasPrefix("XCTest") || key.hasPrefix("XCInject")
                || (key == "DYLD_INSERT_LIBRARIES" && value.contains("XCTest")))
        }
        environment[Self.childFolderVariable] = folder.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        let launched = await waitUntil(timeout: .seconds(90)) { FileManager.default.fileExists(atPath: launchedFile.path) }
        XCTAssertTrue(launched, "the child never started the engine")
        guard launched else { return }
        let enginePID = Self.pid(in: launchedFile)

        let clock = ContinuousClock()
        let signalledAt = clock.now
        kill(child.processIdentifier, SIGTERM)
        let ended = await waitUntil(timeout: .seconds(30)) { !child.isRunning }
        let waited = clock.now - signalledAt
        XCTAssertTrue(ended, "the child did not end within 30 s of the SIGTERM")
        guard ended else { return }

        // At the base the signal ended the child, which a shell reads as exit 143.
        let how = child.terminationReason == .uncaughtSignal
            ? "by signal \(child.terminationStatus), which a shell reads as exit \(128 + child.terminationStatus)"
            : "with status \(child.terminationStatus)"
        XCTAssertEqual(child.terminationReason, .exit, "the SIGTERM ended the command \(how) instead of cancelling the run")
        let outcome = (try? String(contentsOf: folder.appendingPathComponent("outcome"), encoding: .utf8)) ?? "no outcome"
        XCTAssertEqual(outcome, "exit 125", "a cancelled `taxtriage run` exits with CLIExitCode.cancelled")
        XCTAssertLessThan(waited, .seconds(6), "the command outlasted the CLI's 6 s grace (T12), after which the app kills it")

        // The cancel reached the executor's run (S2). The pipeline stopped the engine and handed its
        // cancelled step to the executor, whose root record names the cancel and 125.
        let record = try ProvenanceEnvelopeReader.load(from: folder.appendingPathComponent("output", isDirectory: true))
        // N7 on the CLI route. The cancelled launch leaves its scratch for the sweep, which scans only a
        // project's .tmp/, so this run outside a project removes its own from the system temp folder.
        let work = try String(contentsOf: folder.appendingPathComponent("scratch"), encoding: .utf8)
        let launchScratch = URL(fileURLWithPath: work, isDirectory: true).deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: launchScratch) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchScratch.path), "a cancelled executor launch leaves its scratch for the sweep (N7)")
        XCTAssertEqual(
            record?.workflowName,
            TaxTriageAnalysisRunTool.workflowName,
            "the executor writes the record of the cancelled run, not the pipeline's own save"
        )
        XCTAssertEqual(record?.status, .cancelled, "the run records the cancel")
        XCTAssertEqual(record?.exitStatus, 125)
        XCTAssertNotNil(enginePID, "the child wrote no engine pid")
        if let enginePID {
            XCTAssertFalse(Self.isRunning(enginePID), "the engine outlived the cancelled command")
            XCTAssertEqual(Self.livingProcesses(inGroup: enginePID), [], "a process of the engine's group outlived the cancelled command (SWIFT 3)")
        }
    }

    /// Runs only in the child process that the test above starts.
    func testTaxTriageRunChild() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.childFolderVariable] else {
            throw XCTSkip("Runs only as the child of testASIGTERMCancelsTheRunAndTheCommandExits125")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let engine = try TaxTriageStandInEngine(
            root: folder.appendingPathComponent("engine", isDirectory: true),
            behaviour: .waitsUntilCancelled,
            maximumWait: .seconds(60)
        )
        let reads = folder.appendingPathComponent("S1.fastq")
        let text = (1...3).map { "@S1-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: reads, atomically: true, encoding: .utf8)
        let database = folder.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)

        // Tells the parent when the engine runs, which is when it may signal this process.
        let announce = Task {
            guard let launch = await engine.waitForLaunch(timeout: .seconds(60)),
                  let pid = launch.processIdentifier else { return }
            // The scratch first, so the parent knows it before it may signal this process.
            if let work = launch.workDirectory {
                try? work.write(to: folder.appendingPathComponent("scratch"), atomically: true, encoding: .utf8)
            }
            try? String(pid).write(to: folder.appendingPathComponent("launched"), atomically: true, encoding: .utf8)
        }
        let outcome: String
        do {
            try await Self.runCLI(
                [
                    "run",
                    "--input", reads.path,
                    "--sample", "S1",
                    "--output", folder.appendingPathComponent("output", isDirectory: true).path,
                    "--db", database.path,
                    "--nf-profile", TaxTriageStandInEngine.profile,
                    "--max-cpus", "2",
                    "--quiet",
                ],
                engine: engine
            )
            outcome = "completed"
        } catch let code as ExitCode {
            outcome = "exit \(code.rawValue)"
        } catch {
            outcome = "error \(error)"
        }
        announce.cancel()
        try outcome.write(to: folder.appendingPathComponent("outcome"), atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// Runs `taxtriage run` in this process with the pipeline factory bound to the engine.
    nonisolated private static func runCLI(_ arguments: [String], engine: TaxTriageStandInEngine) async throws {
        let command = try TaxTriageCommand.RunSubcommand.parse(arguments)
        try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
            try await command.run()
        }
    }

    /// The pid the child wrote to `file`, or nil.
    nonisolated private static func pid(in file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Stops the engine whose pid `file` names, if it still runs. The engine leads its own process group.
    nonisolated private static func stopEngine(_ file: URL) {
        guard let pid = pid(in: file), isRunning(pid) else { return }
        kill(-pid, SIGKILL)
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

    /// The pids of the processes in group `group` that have not exited. The engine leads its own group.
    nonisolated private static func livingProcesses(inGroup group: Int32) -> [Int32] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 4)
        size = infos.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &infos, &size, nil, 0) == 0 else { return [] }
        return infos.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { Int32($0.kp_proc.p_stat) != SZOMB }
            .map { $0.kp_proc.p_pid }
    }
}
