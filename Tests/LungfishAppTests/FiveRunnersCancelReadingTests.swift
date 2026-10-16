// FiveRunnersCancelReadingTests.swift - What the five GUI runners of lane S61 do with exit 125 and a signal death
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S61 (K7, risk R7). Primer Trim, the tree actions, Align with MAFFT, the MSA actions
// and the platform label launch `lungfish-cli` through `CLISubprocessTransport`. A command that turns
// SIGTERM into a cancel exits 125 inside the grace, and the row must read that as Cancelled and not as
// a failure. A stand-in CLI plays each ending, so no real command runs.
//
// `convertedRunners` names the runners whose command converts SIGTERM (lane S61 M2 and M3). Those
// runners pass `CLIProcessLauncher.operationGrace`, so a command that records its cancel a moment
// after SIGTERM finishes it. The others still pass no grace, and the transport kills their command at
// once, which is what the first test pins.

import Foundation
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp

@MainActor
final class FiveRunnersCancelReadingTests: XCTestCase {
    /// The runners whose command scopes `SIGTERMCancellation`, by name.
    static let convertedRunners: Set<String> = ["primer-trim"]

    private enum Ending: Equatable {
        case completed
        case cancelled
        case failed(String)
    }

    private struct Running {
        let rowID: UUID?
        let cancel: @MainActor () -> Void
        let ended: Task<Ending, Never>
    }

    private struct Subject {
        let name: String
        let start: @MainActor (_ cli: URL) -> Running
    }

    private var root: URL!
    private var savedCLIPath: String?

    override func setUp() async throws {
        try await super.setUp()
        await OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "five-runners-cancel")
        savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
    }

    override func tearDown() async throws {
        if let savedCLIPath {
            setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The subjects

    private nonisolated static func ending(of body: @Sendable () async throws -> Void) async -> Ending {
        do {
            try await body()
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A row for a runner that takes an operation ID, whose cancel callback is the runner's `cancel()`.
    private func beginRow(cancel: @escaping @Sendable () -> Void) -> UUID {
        let rowID = OperationCenter.shared.begin(
            title: "Five runners cancel test",
            detail: "Launching...",
            operationType: .phylogeneticTreeInference,
            cliCommand: nil
        ).rowID
        OperationCenter.shared.setCancelCallback(for: rowID, callback: cancel)
        return rowID
    }

    private var subjects: [Subject] {
        [
            Subject(name: "primer-trim") { cli in
                let runner = CLIPrimerTrimRunner(cliURLOverride: cli)
                return Running(
                    rowID: nil,
                    cancel: { runner.cancel() },
                    ended: Task { await Self.ending { _ = try await runner.run(arguments: ["bam", "primer-trim"]) } }
                )
            },
            Subject(name: "tree") { cli in
                let runner = CLITreeRunner(label: "tree inference", cliURLOverride: cli)
                let rowID = self.beginRow { runner.cancel() }
                return Running(
                    rowID: rowID,
                    cancel: { OperationCenter.shared.cancel(id: rowID) },
                    ended: Task { await Self.ending { _ = try await runner.run(arguments: ["tree", "infer", "iqtree"], operationID: rowID) } }
                )
            },
            Subject(name: "align mafft") { cli in
                let runner = CLIMSAAlignmentRunner(cliURLOverride: cli)
                let rowID = self.beginRow { runner.cancel() }
                return Running(
                    rowID: rowID,
                    cancel: { OperationCenter.shared.cancel(id: rowID) },
                    ended: Task { await Self.ending { _ = try await runner.run(arguments: ["align", "mafft"], operationID: rowID) } }
                )
            },
            Subject(name: "msa action") { cli in
                let runner = CLIMSAActionRunner(cliURLOverride: cli)
                let rowID = self.beginRow { runner.cancel() }
                return Running(
                    rowID: rowID,
                    cancel: { OperationCenter.shared.cancel(id: rowID) },
                    ended: Task { await Self.ending { _ = try await runner.run(arguments: ["msa", "export"], operationID: rowID) } }
                )
            },
            Subject(name: "fastq platform") { cli in
                setenv("LUNGFISH_CLI_PATH", cli.path, 1)
                let known = Set(OperationCenter.shared.items.map(\.id))
                let (finishes, finish) = AsyncStream<Void>.makeStream()
                FASTQPlatformLabelOperation.run(
                    change: .confirm,
                    bundleURLs: [URL(fileURLWithPath: "/tmp/five-runners-\(UUID().uuidString).lungfishfastq")]
                ) { _ in
                    finish.yield()
                    finish.finish()
                }
                let rowID = OperationCenter.shared.items.first { !known.contains($0.id) }!.id
                return Running(
                    rowID: rowID,
                    cancel: { OperationCenter.shared.cancel(id: rowID) },
                    ended: Task { @MainActor in
                        for await _ in finishes { break }
                        let item = OperationCenter.shared.items.first { $0.id == rowID }
                        switch item?.state {
                        case .completed?: return .completed
                        case .cancelled?: return .cancelled
                        default: return .failed(item?.errorMessage ?? "\(String(describing: item?.state))")
                        }
                    }
                )
            },
        ]
    }

    // MARK: - Stand-in CLIs

    private func standInCLI(named name: String, _ body: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\n\(body)\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }

    private func clearRow(_ running: Running) {
        if let rowID = running.rowID { OperationCenter.shared.clearItem(id: rowID) }
    }

    // MARK: - Tests

    /// A command that converts SIGTERM records its cancel half a second after the signal and exits 125.
    /// Every runner ends Cancelled. A runner that passes the grace lets the command finish, and one that
    /// passes none has the transport kill the command before it records anything.
    func testACancelEndsCancelledAndOnlyAGraceLetsTheCommandRecordIt() async throws {
        for subject in subjects {
            let ready = root.appendingPathComponent("\(subject.name)-ready")
            let marker = root.appendingPathComponent("\(subject.name)-recorded")
            let cli = try standInCLI(
                named: subject.name,
                """
                trap 'sleep 0.5; echo recorded > "\(marker.path)"; exit 125' TERM
                printf '%s\\n' '{"event":"start","progress":0,"message":"starting"}'
                echo ready > "\(ready.path)"
                while :; do sleep 0.1; done
                """
            )
            let running = subject.start(cli)
            guard await CLISIGTERMHarness.waitForFile(ready) else {
                running.cancel()
                return XCTFail("\(subject.name): the stand-in command never started")
            }
            running.cancel()
            let ending = await running.ended.value
            XCTAssertEqual(ending, .cancelled, "\(subject.name): the row reads a cancel as Cancelled")
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: marker.path), Self.convertedRunners.contains(subject.name),
                "\(subject.name): the command records its cancel only when the runner gives it the grace"
            )
            clearRow(running)
        }
    }

    /// A command that dies of the signal, as every command did before lane S61, also ends Cancelled.
    func testACancelOfACommandThatDiesOfTheSignalEndsCancelled() async throws {
        for subject in subjects {
            let ready = root.appendingPathComponent("\(subject.name)-ready")
            let cli = try standInCLI(
                named: subject.name,
                """
                printf '%s\\n' '{"event":"start","progress":0,"message":"starting"}'
                echo ready > "\(ready.path)"
                exec sleep 300
                """
            )
            let running = subject.start(cli)
            guard await CLISIGTERMHarness.waitForFile(ready) else {
                running.cancel()
                return XCTFail("\(subject.name): the stand-in command never started")
            }
            running.cancel()
            let ending = await running.ended.value
            XCTAssertEqual(ending, .cancelled, "\(subject.name): a command killed by the cancel reads Cancelled")
            clearRow(running)
        }
    }

    /// Exit 125 with no cancel from the app is not a cancel the row can name, so it reads as a failure
    /// that states the status. Only a cancel the app asked for ends Cancelled.
    func testExit125WithNoCancelEndsFailedAndStatesTheStatus() async throws {
        for subject in subjects {
            let cli = try standInCLI(
                named: subject.name,
                """
                printf '%s\\n' '{"event":"start","progress":0,"message":"starting"}'
                exit 125
                """
            )
            let running = subject.start(cli)
            let ending = await running.ended.value
            guard case .failed(let message) = ending else {
                XCTFail("\(subject.name): exit 125 with no cancel reads as a failure, not \(ending)")
                clearRow(running)
                continue
            }
            XCTAssertTrue(message.contains("125"), "\(subject.name): the failure states the status: \(message)")
            clearRow(running)
        }
    }

    /// A command killed by a signal the app did not send is a failure, whatever the signal.
    func testASignalDeathWithNoCancelEndsFailed() async throws {
        for subject in subjects {
            let cli = try standInCLI(
                named: subject.name,
                """
                printf '%s\\n' '{"event":"start","progress":0,"message":"starting"}'
                kill -TERM $$
                sleep 5
                """
            )
            let running = subject.start(cli)
            let ending = await running.ended.value
            if case .failed = ending {} else {
                XCTFail("\(subject.name): a signal death with no cancel reads as a failure, not \(ending)")
            }
            clearRow(running)
        }
    }
}
