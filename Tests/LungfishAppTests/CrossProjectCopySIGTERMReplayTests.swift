// CrossProjectCopySIGTERMReplayTests.swift - The sidebar's cross-project copy cancels through the app's transport, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18, review 12.18 Fix 8 (QA 4, SWIFT 3 and 7, X14), on the recipe of
// `ReferenceBundleMergeSIGTERMReplayTests`. The sidebar's cross-project copy runs `project copy-item` on
// `CLIBundleBuildRunner`, whose cancel goes through `CLISubprocessTransport`. ToolProcess signals the leaf's
// process group and tree at once, and the leaf gets `CLIBundleBuildRunner.terminationGracePeriod` before SIGKILL.
// `ProjectCopyItemSIGTERMTests` signals the leaf alone, once, on a quiet machine, and
// `CrossProjectCopyRouteTests.testTheCancelIsReturnedSoTheDropShowsNoAlert` gives the route a launch
// closure that throws, so neither one runs the transport, the row or the grace. Here the leaf copies an item that
// holds a sparse file, with one busy thread for every active processor, five times. Side C is the drop helper
// `copyDroppedProjectItem` with a launch closure on the runner, cancelled once the leaf's stage appears
// in the target project's `.tmp` folder. Side C' is the harness's replay of the command side C recorded, cancelled
// at the same point. Each ends cancelled inside the grace, publishes nothing, leaves no stage, leaves a record that
// reads `cancelled` with exit status 125, and leaves no process of its tree. The row of side C reads Cancelled and
// holds no failure, and the drop helper returns a `CancellationError`.
//
// Since 2.13 row COPY-CANCEL-CHECKS the leaf takes the cancel at the next chunk of the native copy's hashes, so
// the size of the sparse file no longer sets the margin inside the grace. The in-process copy has no cancel, so side A is not
// run. The class launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration
// tier. It needs no real tool.

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
final class CrossProjectCopySIGTERMReplayTests: XCTestCase {
    nonisolated private static let relativePath = "Reference Sequences/Big.lungfishref"
    /// The size of the sparse file the item holds. Before 2.13 row COPY-CANCEL-CHECKS the copy's hashes were the work
    /// a cancel had to wait for, and with 2 GiB the cancel took 4.5 to 5.9 s of the 6 s grace with every core busy, so
    /// the item holds 1 GiB. The leaf now takes the cancel at the next chunk. The 4 GiB case is in
    /// `ProjectCopyItemFourGiBSIGTERMReplayTests`.
    nonisolated private static let sparseBytes: UInt64 = 1 << 30
    /// How many times the copy cancels in one busy window. Whether the leaf takes its cancel before the grace ends
    /// is a race a busy machine decides, so one run proves little.
    private static let repetitions = 5

    /// What side C's own watch and row showed when it cancelled the runner.
    private struct TransportCancel {
        /// The time from the cancel to the drop helper's return, nil when the cancel was never sent.
        let elapsed: Duration?
        /// Every process the test process had started since the run began, read just before the cancel.
        let tree: [Int32]
        /// The state of the Operations row after the drop helper returned, and the error it holds.
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
        scratch = try TestTempDirectory.make(prefix: "cross-project-copy-sigterm")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testTheCopyCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let cancel = RouteParityCancel(
            when: { !Self.stages(in: $0).isEmpty },
            record: { Self.record(in: $0)?.status.rawValue }
        )
        for repetition in 1...Self.repetitions {
            transportCancel = nil
            let runs = try await harness.run(
                in: scratch.appendingPathComponent("run-\(repetition)", isDirectory: true),
                cancel: cancel,
                fixture: { try Self.makeFixture(in: $0) },
                sideA: { _ in
                    RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process copy has no cancel to compare")
                },
                sideC: { root in await self.sideC(root) }
            )

            let observed = try XCTUnwrap(transportCancel, "run \(repetition): side C did not run")
            let elapsed = try XCTUnwrap(observed.elapsed, "run \(repetition), side C: the stage never appeared, so nothing was cancelled")
            print("CrossProjectCopySIGTERMReplayTests run \(repetition) of \(Self.repetitions): cancel to return \(elapsed) on side C, \(String(describing: runs.cPrime.outcome.cancel?.elapsed)) on side C', grace \(CLIBundleBuildRunner.terminationGracePeriod)")
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
                XCTAssertEqual(record?.status.rawValue, "cancelled", "\(label): the record in the target project")
                XCTAssertEqual(record?.exitStatus, 125, "\(label): the leaf exits 125")
                let published = Self.targetProject(in: run.root).appendingPathComponent(Self.relativePath, isDirectory: true)
                XCTAssertFalse(FileManager.default.fileExists(atPath: published.path), "\(label): a cancelled copy publishes no item")
                XCTAssertEqual(Self.stages(in: run.root), [], "\(label): the stage is removed")
            }
        }
    }

    // MARK: - Side C

    /// The drop helper the sidebar calls, with a launch closure on the runner, cancelled through the
    /// runner once the leaf's stage appears. It keeps what its watch and its row showed in `transportCancel`.
    private func sideC(_ root: URL) async -> RouteParitySideOutcome {
        let target = Self.targetProject(in: root)
        let item = Self.sourceProject(in: root).appendingPathComponent(Self.relativePath, isDirectory: true)
        let start = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: item, projectURL: target, requestedFolder: nil, routeContext: nil
        )
        guard let operationID = start.startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused")
        }
        let runner = CLIBundleBuildRunner(cliURLOverride: cli)
        let ended = RunEnded()
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        var watch: Task<(tree: [Int32], sent: ContinuousClock.Instant)?, Never>?
        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: target, requestedFolder: nil, operationID: operationID
        ) { arguments, id in
            watch = Task.detached { () -> (tree: [Int32], sent: ContinuousClock.Instant)? in
                let reached = await LungfishTestSupport.waitUntil(
                    timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)
                ) {
                    ended.isSet || !Self.stages(in: root).isEmpty
                }
                guard reached, !ended.isSet else { return nil }
                let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
                let sent = ContinuousClock.now
                runner.cancel()
                return (tree, sent)
            }
            let run = try await runner.run(arguments: arguments, operationID: id, environmentAdditions: [:])
            return CrossProjectCopyRoute.Run(outputs: run.outputs, message: run.message)
        }
        let endedAt = ContinuousClock.now
        ended.set()
        let sent = await watch?.value
        let row = OperationCenter.shared.items.first { $0.id == operationID }
        transportCancel = TransportCancel(
            elapsed: sent.map { endedAt - $0.sent }, tree: sent?.tree ?? [], rowState: row?.state, rowError: row?.errorMessage
        )
        let end: RouteParityEnd
        let detail: String
        switch result {
        case .success(let landed):
            end = .completed
            detail = "the drop helper returned \(landed.destinationURL.lastPathComponent)"
        case .failure(let error) where error is CancellationError:
            end = .cancelled
            detail = "the drop helper returned CancellationError"
        case .failure(let error):
            end = .failed
            detail = "\(error)"
        }
        return RouteParitySideOutcome(end: end, detail: detail, recordedCommand: row?.cliCommand)
    }

    // MARK: - Fixture

    nonisolated private static func sourceProject(in root: URL) -> URL {
        root.appendingPathComponent("Source.lungfish", isDirectory: true)
    }

    nonisolated private static func targetProject(in root: URL) -> URL {
        root.appendingPathComponent("Target.lungfish", isDirectory: true)
    }

    /// The folders `project copy-item` made for its stage in the target project's `.tmp` folder.
    nonisolated private static func stages(in root: URL) -> [String] {
        let temp = targetProject(in: root).appendingPathComponent(".tmp", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    /// The record the leaf writes in the target project for the run it cancelled.
    nonisolated private static func record(in root: URL) -> ProvenanceEnvelope? {
        ProvenanceRecorder.loadEnvelope(from: targetProject(in: root))
    }

    /// A source project whose reference bundle holds a small FASTA and a sparse file, and an empty target project,
    /// as `ProjectCopyItemSIGTERMTests` makes them. The copier hashes the sparse file before it makes its stage, and
    /// the native copy clones it (instant on APFS) and hashes the source and the clone inside the stage, so the
    /// signal lands while the copy hashes.
    nonisolated private static func makeFixture(in root: URL) throws {
        let fileManager = FileManager.default
        let bundle = sourceProject(in: root).appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: targetProject(in: root), withIntermediateDirectories: true)
        try ">big\nACGT\n".write(to: bundle.appendingPathComponent("sequence.fasta"), atomically: true, encoding: .utf8)
        let sparse = bundle.appendingPathComponent("padding.bin")
        guard fileManager.createFile(atPath: sparse.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: sparse.path])
        }
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: sparseBytes)
        try handle.close()
    }
}
