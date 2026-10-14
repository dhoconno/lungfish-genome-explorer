// AlignmentWorkflowSIGTERMReplayTests.swift - The Inspector's alignment workflows cancel through the app's transport, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54 M3 (decision P2, SWIFT 3, S30 note 2). The row's Cancel reaches a leaf through
// `CLIRunCancellation`, so ToolProcess signals the leaf's process group and its tree at once, and the
// leaf gets `CLIProcessLauncher.operationGrace` before SIGKILL. A leaf that passes `BAMWorkflowLeavesSIGTERMTests`
// signalled alone can still fail here, when its tool dies of the group's SIGTERM before the leaf turns the
// signal into a cancel, and a busy machine widens that window. Each of the four leaves runs against a
// stand-in samtools that writes its process ID and sleeps, with one busy thread for every active processor.
// Side C is cancelled once samtools runs, and so is the replay of the recorded command, side C'. Each must
// exit 125 inside the grace, leave a record that reads `cancelled`, leave its tracks as they were, and leave
// no process of its tree (`RouteParityHarness.assertCancelled`, lane S30's assertions).
//
// The in-process route has no cancelled record, so side A is not run and nothing is compared with it. A
// against C is the parity class's work (`AlignmentWorkflowCLIGUIParityReplayTests`). It launches the built
// lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

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

/// One thread for each active processor, each spinning until `stop()`, so no core is idle while a test
/// runs the leaf. The threads run at the QoS of the app's own work.
final class BusyCores: Sendable {
    private let stopped = Atomic<Bool>(false)
    private let spinning = Atomic<Int>(0)
    let threadCount: Int

    init(threadCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.threadCount = threadCount
    }

    /// How many threads have begun to spin.
    var spinningCount: Int { spinning.load(ordering: .relaxed) }

    func start() {
        for _ in 0..<threadCount {
            let thread = Thread { [self] in
                spinning.add(1, ordering: .relaxed)
                var counter: UInt64 = 0
                while !stopped.load(ordering: .relaxed) { counter &+= 1 }
                spinning.subtract(1, ordering: .relaxed)
                _ = counter
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func stop() {
        stopped.store(true, ordering: .relaxed)
    }
}

@MainActor
final class AlignmentWorkflowSIGTERMReplayTests: XCTestCase {
    typealias Case = AlignmentWorkflowCLIGUIParityReplayTests.Case

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "alignment-workflow-sigterm")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        // Each side reads its samtools from its own root, so side C' stops the same stand-in as side C.
        harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120), environment: { Self.environment(for: $0) }
        )
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    // MARK: - The stand-in samtools

    nonisolated private static func environment(for root: URL) -> [String: String] {
        ["LUNGFISH_CONDA_ROOT": root.appendingPathComponent("conda", isDirectory: true).path]
    }

    nonisolated private static func samtoolsPIDFile(in root: URL) -> URL {
        root.appendingPathComponent("conda/envs/samtools/bin/samtools.pid")
    }

    /// The bundle of the derived-track fixture, whose placeholder BAMs let the leaf reach samtools, and a conda
    /// root whose samtools answers a version probe and sleeps on any other call after it wrote `$$` beside
    /// itself. The leaf reads the root from `LUNGFISH_CONDA_ROOT`, so the stand-in wins over a real samtools.
    nonisolated private static func makeFixture(in root: URL) throws {
        _ = try DerivedAlignmentTrackFixture.make(in: root)
        let script = """
        #!/bin/sh
        case "$*" in
          *version*) echo "samtools 1.20"; exit 0 ;;
        esac
        echo $$ > "$(dirname "$0")/samtools.pid"
        exec sleep 120
        """
        let binary = root.appendingPathComponent("conda/envs/samtools/bin/samtools")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    nonisolated private static func bundleURL(in root: URL) -> URL {
        DerivedAlignmentTrackFixture.existing(in: root).bundleURL
    }

    /// The new bundle the deduplication writes beside its source.
    nonisolated private static func deduplicatedURL(in root: URL) -> URL {
        bundleURL(in: root).deletingLastPathComponent().appendingPathComponent("Sample-deduplicated.lungfishref")
    }

    /// The status of the cancelled record the leaf wrote. Filtering, converting and marking keep it under
    /// `provenance/cancelled` in the bundle they would have changed. Deduplicating keeps it beside the
    /// expected output, because the source bundle must not change.
    nonisolated private static func recordStatus(_ parityCase: Case, in root: URL) throws -> String? {
        if parityCase == .deduplicateAlignments {
            let output = deduplicatedURL(in: root)
            let sidecar = URL(fileURLWithPath: output.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
            return try ProvenanceEnvelopeReader.load(fromSidecar: sidecar)?.status.rawValue
        }
        let folder = bundleURL(in: root).appendingPathComponent("provenance/cancelled", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }
        guard names.count == 1, let name = names.first else { return nil }
        return try ProvenanceEnvelopeReader.load(fromSidecar: folder.appendingPathComponent(name))?.status.rawValue
    }

    // MARK: - The run

    /// How many times a case cancels in one busy window. Whether the leaf's handler runs before its tool's
    /// death is noticed is a race that a busy machine decides, so one run proves little.
    private static let repetitions = 5

    /// Cancels `parityCase` on sides C and C' with every core busy, `repetitions` times, and asserts what S30
    /// asserts of each.
    private func assertCancelsWithEveryCoreBusy(_ parityCase: Case) async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let cancel = RouteParityCancel(
            when: { FileManager.default.fileExists(atPath: Self.samtoolsPIDFile(in: $0).path) },
            record: { try Self.recordStatus(parityCase, in: $0) }
        )
        let cli = cli!
        for repetition in 1...Self.repetitions {
            let runs = try await harness.run(
                in: scratch.appendingPathComponent("\(parityCase.rawValue)-\(repetition)", isDirectory: true),
                cancel: cancel,
                fixture: { try Self.makeFixture(in: $0) },
                sideA: { _ in
                    RouteParitySideOutcome(end: .cancelled, detail: "not run, the in-process route has no cancelled record to compare")
                },
                sideC: { root in
                    let row = try AlignmentWorkflowCLIGUIParityReplayTests.beginRow(parityCase, in: root)
                    let run = await RouteParityHarness.runCLI(
                        cli, arguments: row.arguments, timeout: .seconds(120),
                        environment: Self.environment(for: root), cancelWhen: { cancel.isReached(root) }
                    )
                    return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: row.command, cancel: run.cancel)
                }
            )
            for run in [runs.c, runs.cPrime] {
                XCTAssertEqual(run.outcome.end, .cancelled, "run \(repetition), side \(run.side): \(run.outcome.detail)")
                await RouteParityHarness.assertCancelled(run, cancel)
                XCTAssertEqual(
                    try BundleManifest.load(from: Self.bundleURL(in: run.root)).alignments.count, 2,
                    "run \(repetition), side \(run.side) keeps the tracks it had"
                )
                if parityCase == .deduplicateAlignments {
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: Self.deduplicatedURL(in: run.root).path),
                        "run \(repetition), side \(run.side): a cancelled deduplication leaves no copy"
                    )
                }
            }
        }
    }

    // MARK: - Cases

    func testBamFilterCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        try await assertCancelsWithEveryCoreBusy(.filterAlignment)
    }

    func testBamAnnotateCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        try await assertCancelsWithEveryCoreBusy(.convertMappedReads)
    }

    func testBundleMarkDuplicatesCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        try await assertCancelsWithEveryCoreBusy(.markDuplicates)
    }

    func testBundleDeduplicateAlignmentsCancelsThroughTheTransportWithEveryCoreBusy() async throws {
        try await assertCancelsWithEveryCoreBusy(.deduplicateAlignments)
    }
}
