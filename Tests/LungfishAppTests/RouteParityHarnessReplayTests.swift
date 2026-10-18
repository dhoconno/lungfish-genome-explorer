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
// Lane Q30 M2 adds the terminal states through the real transport (QA 4). A side C that fails
// ends Failed on sides C and C' (translate of a missing input), a warning ends every side
// Completed with Warnings (`import msa` of repeated row names), and a cancel ends every side
// Cancelled and passes lane S30's check on sides C and C' (`workflow run` on the stand-in engine
// S30's suite cancels).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier, where the CLI is built.

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class RouteParityHarnessReplayTests: XCTestCase {
    private var scratch: URL!
    private var harness: RouteParityHarness!

    enum Case: String, Sendable {
        case translate
        case warns
        case cancels
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
            [.translate: 2], "differs: proteins.fasta: <ANY>", scope: .cAgainstCPrime,
            reason: "an entry that tries to declare a difference of C against C'", closedBy: Self.closer
        )
        XCTAssertEqual(
            try harness.evaluate(Case.translate, declared: [entry], runs: runs).failures,
            ["C against C' declares nothing, delete the entry (closed by \(Self.closer)): differs: proteins.fasta: <ANY>"] + expected
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

    // MARK: - Terminal states through the real transport (QA 4)

    /// Side C fails where side A completes. A against C finds the end first, side C' fails the
    /// same way, and C against C' holds nothing.
    func testASideCThatFailsEndsFailedOnBothCLISides() async throws {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("fails", isDirectory: true),
            fixture: Self.writeFixture,
            sideA: { try await self.sideA($0, writesNote: false) },
            sideC: { root in
                let arguments = [
                    "translate", root.appendingPathComponent("missing.fasta").path, "--frame", "1",
                    "--output", root.appendingPathComponent("proteins.fasta").path,
                ]
                let run = await RouteParityHarness.runCLI(self.harness.cliBinary, arguments: arguments, timeout: .seconds(30))
                let command = OperationCenter.buildCLICommand(subcommand: "translate", args: Array(arguments.dropFirst()))
                return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
            }
        )
        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .failed, .failed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        let found = try harness.evaluate(Case.translate, declared: [], runs: runs).found
        XCTAssertEqual(found[.aAgainstC]?.first?.id, "end: A Completed, C Failed")
        XCTAssertEqual(found[.cAgainstCPrime], [])
    }

    /// `import msa` warns that row names repeat and exits 0. Under `--format json` the warning is
    /// an event, so every side ends Completed with Warnings, side C' included, and no side
    /// differs from another.
    func testAWarningEndsEverySideCompletedWithWarnings() async throws {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("warns", isDirectory: true),
            fixture: { root in
                try ">row\nAC-GT\n>row\nACGGT\n".write(to: root.appendingPathComponent("rows.fasta"), atomically: true, encoding: .utf8)
            },
            sideA: { root in
                let run = await RouteParityHarness.runCLI(self.harness.cliBinary, arguments: Self.importArguments(in: root), timeout: .seconds(30))
                return RouteParitySideOutcome(end: run.end, detail: run.detail)
            },
            sideC: { root in
                let arguments = Self.importArguments(in: root)
                let run = await RouteParityHarness.runCLI(self.harness.cliBinary, arguments: arguments, timeout: .seconds(30))
                let command = OperationCenter.buildCLICommand(subcommand: "import msa", args: Array(arguments.dropFirst(2)))
                return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
            }
        )
        XCTAssertEqual(
            runs.all.map(\.outcome.end), [.completedWithWarnings, .completedWithWarnings, .completedWithWarnings],
            runs.all.map(\.outcome.detail).joined(separator: "\n")
        )
        let found = try harness.evaluate(Case.warns, declared: [], runs: runs).found
        XCTAssertEqual(found[.aAgainstC], [])
        XCTAssertEqual(found[.cAgainstCPrime], [])
        XCTAssertEqual(RouteParitySide.allCases.compactMap { found[.side($0)] }, [[], [], []])
    }

    /// A cancel through the real transport on the leaf S30's suites cancel, `workflow run` on a
    /// stand-in Nextflow that starts a stand-in JVM. Each side is cancelled once its stand-in JVM
    /// runs. Every side ends Cancelled, sides C and C' pass S30's check, exit 125 inside the grace,
    /// a cancelled record and no process left (QC-2), and no side differs from another.
    func testACancelEndsEverySideCancelledAndPassesTheSIGTERMCheck() async throws {
        let tools = scratch.appendingPathComponent("tools", isDirectory: true)
        try Self.installNextflowLikeEngine(in: tools.appendingPathComponent("conda", isDirectory: true))
        for folder in ["home", "storage"] {
            try FileManager.default.createDirectory(at: tools.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        let cancelling = RouteParityHarness(
            cliBinary: harness.cliBinary, kind: .bundle, replayTimeout: .seconds(30),
            environment: { root in Self.engineEnvironment(tools: tools, root: root) }
        )
        let cancel = RouteParityCancel(
            when: { root in FileManager.default.fileExists(atPath: Self.pidFile("java", of: root).path) },
            record: { root in
                try LocalWorkflowRunBundleStore.read(from: root.appendingPathComponent("attempt.lungfishrun")).executionStatus.rawValue
            }
        )
        func cancelledRun(_ root: URL, recordsCommand: Bool) async -> RouteParitySideOutcome {
            let arguments = Self.workflowArguments(in: root)
            let run = await RouteParityHarness.runCLI(
                cancelling.cliBinary, arguments: arguments, timeout: .seconds(30),
                environment: cancelling.environment(root), cancelWhen: { cancel.isReached(root) }
            )
            let command = OperationCenter.buildCLICommand(subcommand: "workflow run", args: Array(arguments.dropFirst(2)))
            return RouteParitySideOutcome(
                end: run.end, detail: run.detail, recordedCommand: recordsCommand ? command : nil, cancel: run.cancel
            )
        }
        let runs = try await cancelling.run(
            in: scratch.appendingPathComponent("cancels", isDirectory: true),
            cancel: cancel,
            fixture: { root in
                try "// invented fixture; never executed\n".write(to: root.appendingPathComponent("main.nf"), atomically: true, encoding: .utf8)
            },
            sideA: { await cancelledRun($0, recordsCommand: false) },
            sideC: { await cancelledRun($0, recordsCommand: true) }
        )
        XCTAssertEqual(runs.all.map(\.outcome.end), [.cancelled, .cancelled, .cancelled], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        XCTAssertEqual(runs.cPrime.replayedArguments, [Self.workflowArguments(in: runs.cPrime.root)])
        for side in [runs.c, runs.cPrime] {
            await RouteParityHarness.assertCancelled(side, cancel)
        }

        let found = try cancelling.evaluate(Case.cancels, declared: [], runs: runs).found
        XCTAssertEqual(found[.aAgainstC], [])
        XCTAssertEqual(found[.cAgainstCPrime], [])
        XCTAssertEqual(RouteParitySide.allCases.compactMap { found[.side($0)] }, [[], [], []])
    }

    /// The arguments after the binary of a `workflow run` of `main.nf` in `root`.
    nonisolated static func workflowArguments(in root: URL) -> [String] {
        let results = root.appendingPathComponent("results", isDirectory: true)
        return [
            "workflow", "run", root.appendingPathComponent("main.nf").path,
            "--results-dir", results.path,
            "--expected-output", results.appendingPathComponent("result.txt").path,
            "--bundle-path", root.appendingPathComponent("attempt.lungfishrun").path,
            "--quiet",
        ]
    }

    /// The file the stand-in writes a process ID to for the side whose root is `root`, beside the
    /// side root so the sides' roots stay comparable.
    nonisolated static func pidFile(_ name: String, of root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent).\(name).pid")
    }

    /// The stand-in engine's conda root, home and storage under `tools`, and the process ID files
    /// of the side whose root is `root`.
    nonisolated static func engineEnvironment(tools: URL, root: URL) -> [String: String] {
        [
            "LUNGFISH_CONDA_ROOT": tools.appendingPathComponent("conda", isDirectory: true).path,
            "LUNGFISH_STORAGE_ROOT": tools.appendingPathComponent("storage", isDirectory: true).path,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            "CFFIXED_USER_HOME": tools.appendingPathComponent("home", isDirectory: true).path,
            "ENGINE_PID_FILE": pidFile("engine", of: root).path,
            "JAVA_PID_FILE": pidFile("java", of: root).path,
        ]
    }

    /// A stand-in for the managed Nextflow launcher under `condaRoot`, as WorkflowRunSIGTERMTests
    /// installs it. It records its process ID, starts a background child that stands in for the
    /// JVM and records that one's, and waits.
    static func installNextflowLikeEngine(in condaRoot: URL) throws {
        let script = condaRoot.appendingPathComponent("envs/nextflow/bin/nextflow")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo $$ > "$ENGINE_PID_FILE"
        /bin/sh -c 'echo $$ > "$JAVA_PID_FILE"; exec /bin/sleep 300' &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// The arguments after the binary of an `import msa` of `rows.fasta` in `root`.
    static func importArguments(in root: URL) -> [String] {
        [
            "import", "msa", root.appendingPathComponent("rows.fasta").path,
            "--project", root.path, "--output", root.appendingPathComponent("rows.lungfishmsa").path,
            "--format", "json",
        ]
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
            OperationCenter.buildCLICommand(subcommand: "translate", args: ["/tmp/elsewhere/input.fasta"]),
            "samtools view \(rootA.path)/x.bam",
        ]
        for command in refused {
            XCTAssertThrowsError(try RouteParityHarness.rebased(command, from: rootA, to: rootB), command)
            XCTAssertThrowsError(try RecordedCLICommand.rebased(command, from: rootA, to: rootB), command)
        }
        // The harness also moves the path of a `--name=<path>` word, which the contract rebase refuses (lane 12.16,
        // ruling 3 of the A67 review). RouteParityHarnessRebaseTests pins the split.
        let joined = OperationCenter.buildCLICommand(subcommand: "translate", args: ["--input=\(rootA.path)/input.fasta"])
        XCTAssertEqual(
            try RouteParityHarness.rebased(joined, from: rootA, to: rootB),
            OperationCenter.buildCLICommand(subcommand: "translate", args: ["--input=\(rootB.standardizedFileURL.path)/input.fasta"])
        )
        XCTAssertThrowsError(try RecordedCLICommand.rebased(joined, from: rootA, to: rootB), joined)
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
