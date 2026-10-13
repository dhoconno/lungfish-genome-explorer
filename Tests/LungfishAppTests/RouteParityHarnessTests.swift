// RouteParityHarnessTests.swift - The route parity harness's compare and declared list, with no CLI run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30, review fixes 1 to 3. Each test builds the roots of side A and side C from
// text and calls the harness's compare or declared list directly. No test launches a CLI, so the
// class stays in the unit tier. RouteParityHarnessReplayTests runs the built CLI on all three sides.

import Foundation
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport

final class RouteParityHarnessTests: XCTestCase {
    private var scratch: URL!
    private let harness = RouteParityHarness(cliBinary: URL(fileURLWithPath: "/usr/bin/false"), kind: .bundle)

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "route-parity-harness-unit")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// Completed sides A and C, each a root holding `files` by relative name.
    private func sides(_ filesA: [String: String], _ filesC: [String: String]) throws -> (RouteParitySideRun, RouteParitySideRun) {
        func side(_ side: RouteParitySide, _ files: [String: String]) throws -> RouteParitySideRun {
            let root = scratch.appendingPathComponent(side.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, text) in files {
                try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            return RouteParitySideRun(side: side, root: root, outcome: RouteParitySideOutcome(end: .completed))
        }
        return (try side(.a, filesA), try side(.c, filesC))
    }

    /// A side fact, such as side C recording no command, cannot be declared, so no case skips side C'.
    func testOnlyAAgainstCDeclares() {
        let missing = RouteParityDifference(id: "command: side C records no command")
        let entry = RouteParityDeclaredDifference<String>(
            ["case": 1], missing.id, scope: .side(.c), reason: "an entry that tries to skip the replay", closedBy: "Q30"
        )
        XCTAssertEqual(
            RouteParityHarness.failures(found: [.side(.c): [missing]], parityCase: "case", declared: [entry]),
            [
                "side C declares nothing, delete the entry (closed by Q30): command: side C records no command",
                "side C: not declared: command: side C records no command",
            ]
        )
    }

    /// A `*` in an id is data, such as a stop codon, and only `<ANY>` matches any run of characters.
    func testAStarInAnIdMatchesOnlyAStar() {
        let stop = RouteParityDeclaredDifference<String>(
            ["case": 1], "differs: proteins.fasta: only in C: MAKFGP*MR", reason: "a stop codon", closedBy: "Q30"
        )
        XCTAssertTrue(stop.matches(RouteParityDifference(id: "differs: proteins.fasta: only in C: MAKFGP*MR")))
        XCTAssertFalse(stop.matches(RouteParityDifference(id: "differs: proteins.fasta: only in C: MAKFGPQQMR")))
        let any = RouteParityDeclaredDifference<String>(
            ["case": 1], "differs: proteins.fasta: <ANY>", reason: "any line", closedBy: "Q30"
        )
        XCTAssertTrue(any.matches(RouteParityDifference(id: "differs: proteins.fasta: only in C: MAKFGPQQMR")))
    }
}
