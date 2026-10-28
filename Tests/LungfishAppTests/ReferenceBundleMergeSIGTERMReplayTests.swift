// ReferenceBundleMergeSIGTERMReplayTests.swift - The reference bundle merge cancels through the app's transport, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49, review A49 Fix 3 (SWIFT SC4, ARCH 8). The sidebar's Merge into New Bundle for reference
// bundles runs `bundle merge` on `CLIBundleBuildRunner`, whose cancel goes through `CLISubprocessTransport`.
// ToolProcess signals the leaf's process group and tree at once, and the leaf gets
// `CLIBundleBuildRunner.terminationGracePeriod` before SIGKILL. `BundleMergeSIGTERMTests` signals the leaf alone,
// once, on a quiet machine. Here the leaf runs against a stand-in bgzip that writes its process ID and sleeps, with
// one busy thread for every active processor, five times. Side C is `ReferenceBundleMergeRoute.merge` with a launch
// closure on the runner, cancelled once bgzip runs. Side C' is the harness's replay of the command side C recorded,
// cancelled at the same point. Each ends cancelled inside the grace, publishes nothing, leaves no stage in the
// project's `.tmp`, leaves a record that reads `cancelled` with exit status 125, and leaves no process of its tree.
// The row of side C reads Cancelled and holds no failure.
//
// The in-process merge has no cancelled record, so side A is not run. The class launches the built lungfish-cli, so
// its name ends in ReplayTests and it runs in the integration tier. It needs no real tool.

import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ReferenceBundleMergeSIGTERMReplayTests: XCTestCase {
    nonisolated private static let projectPath = "Project.lungfish"
    /// How many times the merge cancels in one busy window. Whether the leaf's handler runs before its tool's
    /// death is noticed is a race a busy machine decides, so one run proves little.
    private static let repetitions = 5

    /// What side C's own watch and row showed when it cancelled the runner.
    private struct TransportCancel {
        /// The time from the cancel to the route's return, nil when the cancel was never sent.
        let elapsed: Duration?
        /// Every process the test process had started since the run began, read just before the cancel.
        let tree: [Int32]
        /// The state of the Operations row after the route returned, and the error it holds.
        let rowState: OperationCenter.Item.State?
        let rowError: String?
    }

    /// Whether side C's run has ended, set once by the side.
    private final class RunEnded: Sendable {
        private let state = Mutex(false)
        func set() { state.withLock { $0 = true } }
        var isSet: Bool { state.withLock { $0 } }
    }

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!
    private var transportCancel: TransportCancel?

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "reference-merge-sigterm")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // Each side reads its bgzip from its own root, so side C' stops the same stand-in as side C.
        harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120), environment: { Self.environment(for: $0) }
        )
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testTheMergeCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let cancel = RouteParityCancel(
            when: { FileManager.default.fileExists(atPath: Self.bgzipPIDFile(in: $0).path) },
            record: { Self.record(in: $0)?.status.rawValue }
        )
        for repetition in 1...Self.repetitions {
            transportCancel = nil
            let runs = try await harness.run(
                in: scratch.appendingPathComponent("run-\(repetition)", isDirectory: true),
                cancel: cancel,
                fixture: { try Self.makeFixture(in: $0) },
                sideA: { _ in
                    RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process merge has no cancelled record to compare")
                },
                sideC: { root in await self.sideC(root) }
            )

            let observed = try XCTUnwrap(transportCancel, "run \(repetition): side C did not run")
            let elapsed = try XCTUnwrap(observed.elapsed, "run \(repetition), side C: bgzip never ran, so nothing was cancelled")
            XCTAssertLessThanOrEqual(
                elapsed, CLIBundleBuildRunner.terminationGracePeriod,
                "run \(repetition), side C: the leaf ends inside the grace the runner gives it before SIGKILL"
            )
            XCTAssertEqual(observed.rowState, .cancelled, "run \(repetition), side C: the row reads Cancelled")
            XCTAssertNil(observed.rowError, "run \(repetition), side C: the cancelled row holds no failure")
            await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
            await RouteParityHarness.assertCancelled(runs.cPrime, cancel)

            for run in [runs.c, runs.cPrime] {
                let label = "run \(repetition), side \(run.side)"
                XCTAssertEqual(run.outcome.end, .cancelled, "\(label): \(run.outcome.detail)")
                let record = Self.record(in: run.root)
                XCTAssertEqual(record?.status.rawValue, "cancelled", "\(label): the record beside the bundle")
                XCTAssertEqual(record?.exitStatus, 125, "\(label): the leaf exits 125")
                let project = Self.projectURL(in: run.root)
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
                XCTAssertFalse(entries.contains { $0.hasPrefix("Merged") }, "\(label): a cancelled merge publishes no bundle. \(entries)")
                let temp = project.appendingPathComponent(".tmp", isDirectory: true)
                let stages = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
                    .filter { $0.hasPrefix("reference-merge-") }
                XCTAssertEqual(stages, [], "\(label): the stage is removed")
                let pidText = try String(contentsOf: Self.bgzipPIDFile(in: run.root), encoding: .utf8)
                let bgzip = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), label)
                await CLISIGTERMHarness.assertNoProcessLeft([bgzip])
            }
        }
    }

    // MARK: - Side C

    /// The route the sidebar calls and the runner it launches, cancelled through the runner once the stand-in
    /// bgzip runs. It keeps what its watch and its row showed in `transportCancel`.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let project = Self.projectURL(in: root)
        let sources = ["Alpha", "Beta"].map { project.appendingPathComponent("\($0).lungfishref", isDirectory: true) }
        let runner = CLIBundleBuildRunner(cliURLOverride: cli)
        let pidFile = Self.bgzipPIDFile(in: root)
        let ended = RunEnded()
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        var operationID: UUID?
        var watch: Task<(tree: [Int32], sent: ContinuousClock.Instant)?, Never>?
        let end: RouteParityEnd
        let detail: String
        do {
            let merged = try await ReferenceBundleMergeRoute.merge(
                sourceBundleURLs: sources, outputDirectory: project, bundleName: "Merged"
            ) { arguments, id in
                operationID = id
                watch = Task.detached { () -> (tree: [Int32], sent: ContinuousClock.Instant)? in
                    let reached = await LungfishTestSupport.waitUntil(
                        timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)
                    ) {
                        ended.isSet || FileManager.default.fileExists(atPath: pidFile.path)
                    }
                    guard reached, !ended.isSet else { return nil }
                    let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
                    let sent = ContinuousClock.now
                    runner.cancel()
                    return (tree, sent)
                }
                let result = try await runner.run(
                    arguments: arguments, operationID: id, environmentAdditions: Self.environment(for: root)
                )
                return ReferenceBundleMergeRoute.Run(outputs: result.outputs, message: result.message)
            }
            end = .completed
            detail = "the route returned \(merged.lastPathComponent)"
        } catch is CancellationError {
            end = .cancelled
            detail = "the route threw CancellationError"
        } catch {
            end = .failed
            detail = "\(error)"
        }
        let endedAt = ContinuousClock.now
        ended.set()
        let sent = await watch?.value
        let row = operationID.flatMap { id in OperationCenter.shared.items.first { $0.id == id } }
        transportCancel = TransportCancel(
            elapsed: sent.map { endedAt - $0.sent }, tree: sent?.tree ?? [], rowState: row?.state, rowError: row?.errorMessage
        )
        return RouteParitySideOutcome(end: end, detail: detail, recordedCommand: row?.cliCommand)
    }

    // MARK: - Fixture

    nonisolated private static func environment(for root: URL) -> [String: String] {
        ["LUNGFISH_CONDA_ROOT": root.appendingPathComponent("conda", isDirectory: true).path]
    }

    nonisolated private static func projectURL(in root: URL) -> URL {
        root.appendingPathComponent(projectPath, isDirectory: true)
    }

    nonisolated private static func bgzipPIDFile(in root: URL) -> URL {
        root.appendingPathComponent("conda/envs/htslib/bin/bgzip.pid")
    }

    /// The record the leaf writes in the output folder, the project, for the run it cancelled.
    nonisolated private static func record(in root: URL) -> ProvenanceEnvelope? {
        ProvenanceRecorder.loadEnvelope(from: projectURL(in: root))
    }

    /// A project with two source bundles that hold a plain FASTA each, so reading them needs no tool (the bundles
    /// and the stand-in conda root are copied from `BundleMergeSIGTERMTests`, since the two test targets share no
    /// file), and a conda root whose bgzip and samtools answer a version probe and whose bgzip sleeps on any other
    /// call after it wrote `$$` beside itself. The write goes to a temporary file that moves into place, so
    /// `bgzip.pid` never exists empty. Both cancel watches fire on that file's existence, and a SIGTERM that landed
    /// between the shell's create and its write once left an empty file, which `Int32(...)` read as nil (item 10).
    /// The leaf reads the root from `LUNGFISH_CONDA_ROOT`, so the stand-ins win over a real tool.
    nonisolated private static func makeFixture(in root: URL) throws {
        let fileManager = FileManager.default
        let project = projectURL(in: root)
        for (name, sequence) in [("Alpha", "chrA"), ("Beta", "chrB")] {
            let genome = project.appendingPathComponent("\(name).lungfishref/genome", isDirectory: true)
            try fileManager.createDirectory(at: genome, withIntermediateDirectories: true)
            try ">\(sequence)\nACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT\n"
                .write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        }

        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        d=$(dirname "$0")
        echo $$ > "$d/bgzip.pid.tmp"
        /bin/mv "$d/bgzip.pid.tmp" "$d/bgzip.pid"
        exec sleep 120
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("conda/envs/htslib/bin/bgzip", bgzip), ("conda/envs/samtools/bin/samtools", samtools)] {
            let binary = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }
}
