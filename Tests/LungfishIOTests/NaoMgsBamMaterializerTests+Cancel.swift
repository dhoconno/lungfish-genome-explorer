// NaoMgsBamMaterializerTests+Cancel.swift - A writer error ends the NAO-MGS samtools pipeline and leaves no process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

extension NaoMgsBamMaterializerTests {

    /// A writer error while both stages are alive cancels the run and leaves no process (lane 13.09 SWIFT fix 2).
    ///
    /// Each stage records its own pid and the pid of a `sleep 30` it starts, so a stage the cancel misses, or a
    /// grandchild it leaves behind, shows by pid. The first stage waits until all four pids are on file, then closes
    /// its stdin and stays alive. The rows overfill the pipe, so the writer is waiting and meets a broken pipe while
    /// the whole pipeline still runs. Closing the first stage's stdin, not its exit, matters, since a stage that
    /// exits ends the run by itself and the cancel would find nothing to stop.
    func testAWriterErrorCancelsALivePipelineAndLeavesNoProcess() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent("naomgs.sqlite")
        try makeTestDatabase(at: dbURL, sample: "PinCancel", duplicateCount: 0)
        try addSingleEndRows(to: dbURL, sample: "PinCancel", count: 2000)
        let pids = tmp.appendingPathComponent("pids").path
        let fake = try makeFakeSamtools(in: tmp, body: """
            echo $$ >> '\(pids)'
            sleep 30 &
            echo $! >> '\(pids)'
            if [ "$1" = view ]; then
              waited=0
              while [ $(($(wc -l < '\(pids)'))) -lt 4 ] && [ $waited -lt 300 ]; do
                sleep 0.1
                waited=$((waited + 1))
              done
              exec 0<&-
            fi
            wait
            """)
        let start = Date()
        let result = try materializeForPin(dbURL: dbURL, tmp: tmp, samtools: fake, markDuplicates: false)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.bamURLs, [])
        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertEqual(try materializerWarnings(forSample: "PinCancel", since: start), [
            "Failed to materialize BAM for sample PinCancel: Broken pipe writing SAM record for sample PinCancel",
        ])
        // The cancel ends both stages at once. Without it the writer's error waits for the stages' 30 s sleeps.
        XCTAssertLessThan(elapsed, 10, "the cancel should end the live stages at once")

        let recorded = try String(contentsOfFile: pids, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        XCTAssertEqual(recorded.count, 4, "each stage records its pid and its sleep's pid")
        // A killed grandchild is reaped by launchd, so give it a moment to leave the process table.
        var living = recorded
        let deadline = Date().addingTimeInterval(30)
        while !living.isEmpty && Date() < deadline {
            living = living.filter { !(Darwin.kill($0, 0) == -1 && errno == ESRCH) }
            if !living.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertEqual(living, [], "processes still alive after the cancel")
    }
}
