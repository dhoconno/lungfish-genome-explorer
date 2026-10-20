// ProjectCopyItemFourGiBSIGTERMReplayTests.swift - A copy of a 4 GiB item takes SIGTERM inside the grace, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.36 (row COPY-CANCEL-CHECKS, QA and SWIFT 7). `ProjectCopyItemSIGTERMTests` holds the leaf with
// a sparse file of 512 MiB on a quiet machine. This class gives the item a sparse file of 4 GiB and keeps one busy
// thread on every active processor, so a cancel that waits for the native copy's hashes misses the 6.0 s the app
// gives the leaf before SIGKILL. The copier hashes the item once, with a check between chunks, before it makes its
// stage. The test sends SIGTERM when the stage appears, so the signal lands while the native copy hashes the source.
// The leaf must exit 125 inside the grace with its record cancelled, write the `failed` event, publish nothing and
// leave no stage. A 4 GiB file is too much work for the unit tier, so the class name ends in ReplayTests and the
// integration tier runs it. It launches the built lungfish-cli and needs no real tool.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ProjectCopyItemFourGiBSIGTERMReplayTests: XCTestCase {
    nonisolated private static let relativePath = "Reference Sequences/Big.lungfishref"
    /// The size of the sparse file the item holds. Each pass of SHA-256 over it takes seconds with every core busy.
    nonisolated private static let sparseBytes: UInt64 = 4 << 30
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "project-copy-item-4gib")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testAFourGiBCopyTakesSIGTERMInsideTheGraceWithEveryCoreBusy() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")

        let source = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        let target = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        try Self.makeFixture(source: source, target: target)
        let run = try CLISIGTERMHarness.launchCLI(
            [
                "project", "copy-item", Self.relativePath,
                "--source-project", source.path, "--project", target.path, "--format", "json",
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let temp = target.appendingPathComponent(".tmp", isDirectory: true)
        // The copier hashes the 4 GiB file once before it makes the stage. That took about 22 s of the base run with every
        // core busy (build/lane/m0-4gib-base.log), so this wait is not the 30 s of a process start. The grace is timed from SIGTERM.
        let staged = await waitUntil(timeout: .seconds(90), pollInterval: .milliseconds(10)) {
            !Self.stages(in: temp).isEmpty
        }
        XCTAssertTrue(staged, "the leaf never made its stage")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
            ProvenanceRecorder.loadEnvelope(from: target)?.status.rawValue
        })
        print("ProjectCopyItemFourGiBSIGTERMReplayTests: SIGTERM to exit \(String(describing: stop.elapsed)), grace \(CLISIGTERMHarness.operationGrace)")

        let published = target.appendingPathComponent(Self.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path), "a cancelled copy publishes no item")
        XCTAssertEqual(Self.stages(in: temp), [], "the stage is removed")
        let lines = stop.standardOutput.split(separator: "\n").map(String.init)
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any], "\(lines)"
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)")
        XCTAssertEqual((last["error"] ?? last["message"]) as? String, "Copy cancelled. Nothing was published.")
    }

    /// The folders `project copy-item` made for its stage in the target project's `.tmp` folder.
    nonisolated private static func stages(in temp: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    /// A source project whose reference bundle holds a small FASTA and a sparse file of 4 GiB, and an empty target
    /// project, as `ProjectCopyItemSIGTERMTests` makes them.
    nonisolated private static func makeFixture(source: URL, target: URL) throws {
        let fileManager = FileManager.default
        let item = source.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: item, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try ">big\nACGT\n".write(to: item.appendingPathComponent("sequence.fasta"), atomically: true, encoding: .utf8)
        let sparse = item.appendingPathComponent("padding.bin")
        guard fileManager.createFile(atPath: sparse.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: sparse.path])
        }
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: sparseBytes)
        try handle.close()
    }
}
