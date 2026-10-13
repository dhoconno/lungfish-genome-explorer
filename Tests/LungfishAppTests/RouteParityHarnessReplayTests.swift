// RouteParityHarnessReplayTests.swift - The shared route parity harness checks itself on lungfish-cli translate
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30 (QA 2, QA 5, QA 6). Every family's parity class runs on
// Tests/Support/LungfishKitTestSupport/RouteParityHarness.swift, so the harness must fail a case
// for each thing it guards. Each test runs `lungfish-cli translate`, a pure Swift command that
// writes a protein FASTA and its provenance records, on the three sides of one case. Side C runs
// the built CLI through the real transport and records the command its row would show, side C'
// is the harness's replay of that command, and side A stands in for an in-process route with the
// same run plus what each test changes. Routes that agree pass with their one declared
// difference counted, and an undeclared difference, a wrong count and one changed byte each fail.
// The harness's rebase is the contract's.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier, where the CLI is built.

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class RouteParityHarnessReplayTests: XCTestCase {
    private var scratch: URL!
    private var harness: RouteParityHarness!

    enum Case: String, Sendable {
        case translate
    }

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "route-parity-harness")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(30))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - Routes that agree

    func testRoutesThatAgreePassWithTheirOneDeclaredDifferenceCounted() async throws {
        let caseRoot = scratch.appendingPathComponent("agree", isDirectory: true)
        let result = try await harness.assertParity(
            Case.translate,
            declared: [Self.strayNote(count: 1)],
            in: caseRoot,
            fixture: Self.writeFixture,
            sideA: { try await self.sideA($0, writesNote: true) },
            sideC: { try await self.sideC($0) }
        )
        XCTAssertEqual(result.found[.aAgainstC]?.map(\.id), ["only in A: route-a-note.txt"])
        XCTAssertEqual(result.found[.cAgainstCPrime], [])
        XCTAssertEqual(result.failures, [])
        // Side C' replayed side C's command, rebased onto its own root, and wrote what C wrote.
        let cPrime = result.runs.cPrime
        XCTAssertEqual(cPrime.replayedArguments, [Self.translateArguments(in: cPrime.root)])
        XCTAssertEqual(cPrime.outcome.end, .completed, cPrime.outcome.detail)
        for name in ["proteins.fasta", "proteins.fasta.lungfish-provenance.json", ".lungfish-provenance.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: cPrime.root.appendingPathComponent(name).path), name)
        }
    }

    // MARK: - Each guard fails a case

    func testAnUndeclaredDifferenceFails() async throws {
        let runs = try await runSides(writesNote: true)
        let failures = try harness.evaluate(Case.translate, declared: [], runs: runs).failures
        XCTAssertEqual(failures, ["A against C: not declared: only in A: route-a-note.txt"])
        XCTExpectFailure("a case with an undeclared difference fails its test") {
            RouteParityHarness.assertNoFailures(failures, in: "\(Case.translate)")
        }
    }

    func testAWrongCountFails() async throws {
        let withNote = try await runSides(writesNote: true)
        let tooMany = try harness.evaluate(Case.translate, declared: [Self.strayNote(count: 2)], runs: withNote).failures
        XCTAssertEqual(tooMany, [
            "A against C: 1 differences match, 2 declared for translate (closed by \(Self.closer)): only in A: route-a-note.txt"
                + "\n        only in A: route-a-note.txt",
        ])
        // A difference that has gone fails its entry too, so a closed difference leaves the list.
        let withoutNote = try await runSides(writesNote: false)
        let gone = try harness.evaluate(Case.translate, declared: [Self.strayNote(count: 1)], runs: withoutNote).failures
        XCTAssertEqual(gone, [
            "A against C: declared but gone, delete translate from the entry (closed by \(Self.closer)): only in A: route-a-note.txt",
        ])
        XCTExpectFailure("a case whose declared count does not hold fails its test") {
            RouteParityHarness.assertNoFailures(tooMany + gone, in: "\(Case.translate)")
        }
    }

    /// One byte of side C''s proteins changes after the replay. C against C' finds the line it is
    /// on, and no entry can declare it.
    func testOneChangedByteInTheReplayFailsAndCannotBeDeclared() async throws {
        let runs = try await runSides(writesNote: false)
        XCTAssertEqual(try harness.evaluate(Case.translate, declared: [], runs: runs).failures, [])

        let proteins = runs.cPrime.root.appendingPathComponent("proteins.fasta")
        let original = try String(contentsOf: proteins, encoding: .utf8)
        let line = try XCTUnwrap(original.components(separatedBy: "\n").first { $0.hasPrefix("M") }, original)
        let changed = "L" + line.dropFirst()
        try Self.replaceOnce(line, with: changed, in: proteins)
        XCTAssertEqual(try Data(contentsOf: proteins).count, Data(original.utf8).count, "one byte changed, none added")

        let expected = [
            "C against C': not declared: differs: proteins.fasta: only in C: \(line)",
            "C against C': not declared: differs: proteins.fasta: only in C': \(changed)",
        ]
        XCTAssertEqual(try harness.evaluate(Case.translate, declared: [], runs: runs).failures, expected)
        let entry = RouteParityDeclaredDifference<Case>(
            [.translate: 2], "differs: proteins.fasta: *", scope: .cAgainstCPrime,
            reason: "an entry that tries to declare a difference of C against C'", closedBy: Self.closer
        )
        XCTAssertEqual(
            try harness.evaluate(Case.translate, declared: [entry], runs: runs).failures,
            ["C against C' declares nothing, delete the entry (closed by \(Self.closer)): differs: proteins.fasta: *"] + expected
        )
    }

    /// Side A's record differs from side C's in one declared value and one byte more. The value
    /// beside the declared one fails, so no declared value covers the rest of its file.
    func testOneChangedByteBesideADeclaredValueFails() async throws {
        let workflowName = ("\"workflowName\" : \"lungfish translate\"", "\"workflowName\" : \"lungfish translatf\"")
        let status = ("\"status\" : \"completed\"", "\"status\" : \"completef\"")
        let declared = [
            RouteParityDeclaredDifference<Case>(
                [.translate: 1], "differs: proteins.fasta.lungfish-provenance.json at workflowName",
                reason: "side A's record names its workflow with one byte changed", closedBy: Self.closer
            ),
        ]
        let oneValue = try await runSides(writesNote: false, recordEdits: [workflowName])
        XCTAssertEqual(try harness.evaluate(Case.translate, declared: declared, runs: oneValue).failures, [])

        let twoValues = try await runSides(writesNote: false, recordEdits: [workflowName, status])
        XCTAssertEqual(try harness.evaluate(Case.translate, declared: declared, runs: twoValues).failures, [
            "A against C: not declared: differs: proteins.fasta.lungfish-provenance.json at status\n        A \"completef\", C \"completed\"",
        ])
    }

    // MARK: - The rebase

    func testTheHarnessRebaseIsTheContractRebase() throws {
        let rootA = scratch.appendingPathComponent("A", isDirectory: true)
        let rootB = scratch.appendingPathComponent("B", isDirectory: true)
        let script = [
            OperationCenter.buildCLICommand(subcommand: "translate", args: [
                rootA.appendingPathComponent("input.fasta").path, "--output", rootA.appendingPathComponent("out dir/p.fasta").path,
            ]),
            OperationCenter.buildCLICommand(subcommand: "translate", args: [rootA.appendingPathComponent("out dir/p.fasta").path]),
        ].joined(separator: "\n")
        XCTAssertEqual(
            try RouteParityHarness.rebased(script, from: rootA, to: rootB),
            try RecordedCLICommand.rebased(script, from: rootA, to: rootB)
        )
        let refused = [
            OperationCenter.buildCLICommand(subcommand: "translate", args: ["--input=\(rootA.path)/input.fasta"]),
            OperationCenter.buildCLICommand(subcommand: "translate", args: ["/tmp/elsewhere/input.fasta"]),
            "samtools view \(rootA.path)/x.bam",
        ]
        for command in refused {
            XCTAssertThrowsError(try RouteParityHarness.rebased(command, from: rootA, to: rootB), command)
            XCTAssertThrowsError(try RecordedCLICommand.rebased(command, from: rootA, to: rootB), command)
        }
    }

    // MARK: - The sides

    static let closer = "lane Q30's self-test"

    /// The stray file side A writes, declared for the translate case.
    static func strayNote(count: Int) -> RouteParityDeclaredDifference<Case> {
        RouteParityDeclaredDifference(
            [.translate: count], "only in A: route-a-note.txt",
            reason: "side A writes a note that side C does not", closedBy: closer
        )
    }

    /// One FASTA of two sequences.
    static func writeFixture(_ root: URL) throws {
        try ">seqA\nATGGCCAAATTTGGGCCCTAAATGCGT\n>seqB\nATGAAACCCGGGTTTTAG\n"
            .write(to: root.appendingPathComponent("input.fasta"), atomically: true, encoding: .utf8)
    }

    /// The arguments after the binary of the run in `root`.
    static func translateArguments(in root: URL) -> [String] {
        [
            "translate", root.appendingPathComponent("input.fasta").path, "--frame", "1",
            "--output", root.appendingPathComponent("proteins.fasta").path,
        ]
    }

    /// Side C. The built CLI through the real transport, recording the command a row would show.
    private func sideC(_ root: URL) async throws -> RouteParitySideOutcome {
        let arguments = Self.translateArguments(in: root)
        let run = await RouteParityHarness.runCLI(harness.cliBinary, arguments: arguments, timeout: .seconds(30))
        let command = OperationCenter.buildCLICommand(subcommand: "translate", args: Array(arguments.dropFirst()))
        return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
    }

    /// Side A. The same run, then a note only side A writes and the edits of its record.
    private func sideA(_ root: URL, writesNote: Bool, recordEdits: [(String, String)] = []) async throws -> RouteParitySideOutcome {
        let run = await RouteParityHarness.runCLI(harness.cliBinary, arguments: Self.translateArguments(in: root), timeout: .seconds(30))
        if writesNote {
            try "written by side A only\n".write(to: root.appendingPathComponent("route-a-note.txt"), atomically: true, encoding: .utf8)
        }
        for (text, replacement) in recordEdits {
            try Self.replaceOnce(text, with: replacement, in: root.appendingPathComponent("proteins.fasta.lungfish-provenance.json"))
        }
        return RouteParitySideOutcome(end: run.end, detail: run.detail)
    }

    private func runSides(writesNote: Bool, recordEdits: [(String, String)] = []) async throws -> RouteParityRuns {
        try await harness.run(
            in: scratch.appendingPathComponent(UUID().uuidString, isDirectory: true),
            fixture: Self.writeFixture,
            sideA: { try await self.sideA($0, writesNote: writesNote, recordEdits: recordEdits) },
            sideC: { try await self.sideC($0) }
        )
    }

    /// Replaces the one occurrence of `text` in the file at `url`.
    static func replaceOnce(_ text: String, with replacement: String, in url: URL) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: text).count, 2, "\(url.lastPathComponent) holds \(text) once")
        let range = try XCTUnwrap(contents.range(of: text), "\(url.lastPathComponent) holds no \(text)")
        try contents.replacingCharacters(in: range, with: replacement).write(to: url, atomically: true, encoding: .utf8)
    }
}
