// ProjectCopyItemSIGTERMTests.swift - A SIGTERM cancels project copy-item before it publishes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 M2 (SWIFT inv 85). The app's Cancel sends SIGTERM to the leaf and gives it
// `operationGrace`. The leaf turns the signal into a cancel of the copy, publishes nothing, removes its
// stage from the target project's `.tmp` folder, records the run as cancelled, exits 125 and leaves no
// process behind.
//
// What holds the command. The copy runs no tool, so no stand-in can hold it. The item holds a sparse file
// of 512 MiB instead, the way `VariantsImportSampleMetadataSIGTERMTests` holds its command. The copier
// hashes it once, with a check between chunks, before it makes its stage. The native copy then hashes the
// source with a check between chunks, clones it (instant on APFS) and hashes the clone the same way, so the
// leaf takes the cancel at the next chunk and its time after SIGTERM does not grow with the item's size (2.13
// row COPY-CANCEL-CHECKS, held at 4 GiB by `ProjectCopyItemFourGiBSIGTERMReplayTests`). The test sends SIGTERM
// when the stage appears, so the signal lands while the native copy hashes the source. Before that row a loaded
// Mac needed 9.4 s at 2 GiB, past the 6.0 s grace, and 512 MiB keeps the signal inside the native copy.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class ProjectCopyItemSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "project-copy-item-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testACopyTurnsSIGTERMIntoACancelAndPublishesNoPartialItem() async throws {
        let source = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        let target = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        let item = source.appendingPathComponent("Reference Sequences/Big.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try ">big\nACGT\n".write(to: item.appendingPathComponent("sequence.fasta"), atomically: true, encoding: .utf8)
        let sparse = item.appendingPathComponent("padding.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 512 << 20)
        try handle.close()

        let run = try CLISIGTERMHarness.launchCLI(
            [
                "project", "copy-item", "Reference Sequences/Big.lungfishref",
                "--source-project", source.path, "--project", target.path, "--format", "json",
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let temp = target.appendingPathComponent(".tmp", isDirectory: true)
        let staged = await waitUntilStaged(in: temp)
        XCTAssertTrue(staged, "the leaf never made its stage")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
            ProvenanceRecorder.loadEnvelope(from: target)?.status.rawValue
        })

        let published = target.appendingPathComponent("Reference Sequences/Big.lungfishref")
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path), "a cancelled copy publishes no item")
        XCTAssertEqual(stages(in: temp), [], "the stage is removed")
        let lines = stop.standardOutput.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.first?.contains("Copying Big.lungfishref") == true, "the row's first words. \(lines)")
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data((lines.last ?? "").utf8)) as? [String: Any], "\(lines)"
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last line is the failed event. \(lines)")
        XCTAssertEqual((last["error"] ?? last["message"]) as? String, "Copy cancelled. Nothing was published.")
    }

    private func stages(in temp: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    /// Waits up to 30 seconds for the copier's stage, polling every 10 milliseconds.
    private func waitUntilStaged(in temp: URL) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if !stages(in: temp).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
