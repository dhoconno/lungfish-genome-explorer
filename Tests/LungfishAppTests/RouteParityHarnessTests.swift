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

    /// One changed line and a reorder in one file give the line and the order, so a declared line cannot cover the reorder.
    func testAReorderBesideAnExplainedLineIsFound() throws {
        let (a, c) = try sides(["rows.tsv": "head\nx\ny\n"], ["rows.tsv": "head2\ny\nx\n"])
        XCTAssertEqual(try harness.differences(a, c).map(\.id), [
            "differs: rows.tsv: only in A: head",
            "differs: rows.tsv: only in C: head2",
            "differs: rows.tsv: line order",
        ])
    }

    /// Side C's record swaps its input and output links beside a value that differs anyway. The
    /// explanation reads the record as the comparison did, with UUIDs numbered across each tree,
    /// so the swapped links are found beside the value and cannot hide under its entry (review fix 4).
    func testASwappedRecordLinkBesideADeclaredValueIsFound() throws {
        let (u1, u2, v1, v2) = (UUID().uuidString, UUID().uuidString, UUID().uuidString, UUID().uuidString)
        let (a, c) = try sides(
            ["in-\(u1).txt": "x\n", "out-\(u2).txt": "y\n",
             "run.lungfish-provenance.json": #"{"input":"\#(u1)","output":"\#(u2)","tool":"a"}"#],
            ["in-\(v1).txt": "x\n", "out-\(v2).txt": "y\n",
             "run.lungfish-provenance.json": #"{"input":"\#(v2)","output":"\#(v1)","tool":"c"}"#]
        )
        XCTAssertEqual(try harness.differences(a, c).map(\.id), [
            "differs: run.lungfish-provenance.json at input",
            "differs: run.lungfish-provenance.json at output",
            "differs: run.lungfish-provenance.json at tool",
        ])
    }

    // MARK: - What stays one difference

    /// A gzip file is explained by its decompressed lines, as the comparison reads it (BIO B-1).
    func testAGzipFileIsExplainedByItsDecompressedLines() throws {
        let (a, c) = try sides(["reads.txt": "head\nx\n"], ["reads.txt": "head\ny\n"])
        for root in [a.root, c.root] {
            try Self.gzip(root.appendingPathComponent("reads.txt"))
        }
        XCTAssertEqual(try harness.differences(a, c).map(\.id), [
            "differs: reads.txt.gz: only in A: x",
            "differs: reads.txt.gz: only in C: y",
        ])
    }

    /// A file whose lines differ only in order is that one difference, which an entry may declare.
    func testAFileThatDiffersOnlyInOrderIsOneLineOrderDifference() throws {
        let (a, c) = try sides(["rows.tsv": "x\ny\n"], ["rows.tsv": "y\nx\n"])
        XCTAssertEqual(try harness.differences(a, c).map(\.id), ["differs: rows.tsv: line order"])
    }

    /// A binary file and a file with more lines changed than the explanation lists each stay one
    /// whole-file difference, and an entry that matches one fails (panel G5, BIO B-7).
    func testAWholeFileDifferenceCannotBeDeclared() throws {
        let many = (1...51).map { "row \($0)" }
        let (a, c) = try sides(
            ["rows.tsv": many.joined(separator: "\n"), "notes.txt": "kept\n"],
            ["rows.tsv": many.map { $0 + " changed" }.joined(separator: "\n"), "notes.txt": "kept\n"]
        )
        try Data([0xff, 0xfe, 0x00, 0x01]).write(to: a.root.appendingPathComponent("blob.bin"))
        try Data([0xff, 0xfe, 0x00, 0x02]).write(to: c.root.appendingPathComponent("blob.bin"))
        let found = try harness.differences(a, c)
        XCTAssertEqual(found.map(\.id), ["differs: blob.bin", "differs: rows.tsv"])
        XCTAssertEqual(found.map(\.wholeFile), [true, true])

        let entry = RouteParityDeclaredDifference<String>(
            ["case": 1], "differs: rows.tsv<ANY>", reason: "an entry that tries to declare a whole file", closedBy: "Q30"
        )
        let failures = RouteParityHarness.failures(found: [.aAgainstC: found], parityCase: "case", declared: [entry])
        XCTAssertEqual(failures.map { $0.components(separatedBy: "\n")[0] }, [
            "A against C: not declared: differs: blob.bin",
            "A against C: not declared: differs: rows.tsv",
            "A against C: a whole file cannot be declared, narrow the entry or show the file the same (closed by Q30): differs: rows.tsv<ANY>",
        ])
    }

    // MARK: - Each side's own facts

    /// A file a side wrote that names another side's root is a fact of that side, which no entry
    /// declares. A fixture file that names root A and that no side changed is left out.
    @MainActor
    func testAFileThatNamesAnotherSidesRootIsAFact() async throws {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("case", isDirectory: true),
            fixture: { root in
                try "built in \(root.path)\n".write(to: root.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
            },
            sideA: { _ in RouteParitySideOutcome(end: .completed) },
            sideC: { root in
                let rootA = RouteParityHarness.root(of: .a, in: root.deletingLastPathComponent())
                try #"{"input":"\#(rootA.path)/fixture.txt"}"#
                    .write(to: root.appendingPathComponent("run.lungfish-provenance.json"), atomically: true, encoding: .utf8)
                return RouteParitySideOutcome(end: .completed)
            }
        )
        let found = try harness.differences(of: runs)
        XCTAssertEqual(found[.side(.a)], [])
        XCTAssertEqual(found[.side(.c)]?.map(\.id), [
            "fact: run.lungfish-provenance.json names the root of side A",
            "command: side C records no command",
        ])
        XCTAssertEqual(found[.side(.cPrime)], [])
    }

    /// Compresses `file` in place with gzip, which leaves `<file>.gz`.
    private static func gzip(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip \(file.lastPathComponent)")
    }
}
