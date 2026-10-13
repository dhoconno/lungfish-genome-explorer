// RouteParityHarness.swift - The shared route parity harness, sides A, C and C' of every family's parity class
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30, panel decisions G1, C13 and G5 in docs/plans/2026-10-13-phase-2-10.md, and
// docs/contracts/CLI-EQUIVALENCE.md. Every batch 1 family moves an in-process GUI route onto
// `lungfish-cli` and shows that both routes give the same result. Its parity class runs each case
// on three sides, in three sibling roots that start as copies of one fixture.
//
// - Side A is the in-process route at the base, the GUI path the family replaces.
// - Side C is the CLI route, the GUI path that launches the built `lungfish-cli`. Its row records
//   the command.
// - Side C' is that recorded command, rebased from root C onto root C' and run by the same built
//   CLI through `CLIProcessLauncher`, the launch every CLI route of the app uses.
//
// The harness compares A against C and C against C' with `OutputEquivalence` over the whole side
// root, so a stray write shows too, and compares how each side ended
// (RouteParityHarness+Compare.swift). A file that differs gives one difference for each value or
// line that differs, read from the texts the comparison compared, so a declared difference never
// covers a whole file. No side's files name another side's root. A against C may declare
// differences, each with its reason, the lane that closes it and an exact count for each case
// (RouteParityHarness+Declared.swift). A count that no longer holds fails, so the list only
// shrinks and a new difference cannot hide under an old entry. C against C' declares nothing.
//
//     let harness = RouteParityHarness(cliBinary: cli, kind: .bundle)
//     try await harness.assertParity(
//         Case.addAnnotation, declared: Self.declared, in: caseRoot,
//         fixture: { root in try Fixture.makeBundle(in: root) },
//         sideA: { root in try await Self.inProcessRoute(root) },
//         sideC: { root in try await Self.cliRoute(root) }
//     )
//
// Stand-in tools that answer both sides come in through `environment`, from each side's root. A
// case that cancels passes a `RouteParityCancel`, side C cancels its run at that point through
// `runCLI`, side C' is cancelled at the same point, and `assertParity` checks both with lane
// S30's assertions (RouteParityHarness+Cancel.swift).
//
// A class that runs an external tool ends in `ReplayTests`, which sends it to the integration
// tier. `LUNGFISH_PARITY_DUMP=<folder>` keeps each case's roots and findings in that folder, the
// way the counts of a declared list are read.

import Foundation
import LungfishTestSupport
import XCTest

/// The three sides of a route parity case.
public enum RouteParitySide: String, CaseIterable, Sendable, CustomStringConvertible {
    /// The in-process route at the base.
    case a = "A"
    /// The CLI route. Its row records the command that reproduces the run.
    case c = "C"
    /// The command side C recorded, rebased onto root C' and run by the built CLI.
    case cPrime = "C'"

    public var description: String { rawValue }

    /// The folder of the side's root, a name a recorded command needs no quotes for.
    public var folderName: String {
        switch self {
        case .a: return "A-route"
        case .c: return "C-route"
        case .cPrime: return "C-replay"
        }
    }
}

/// How a side's run ended, in the words of its Operations panel row.
public enum RouteParityEnd: String, Sendable, CustomStringConvertible {
    case completed = "Completed"
    case completedWithWarnings = "Completed with Warnings"
    case failed = "Failed"
    case cancelled = "Cancelled"

    public var description: String { rawValue }

    /// How a CLI run that exited with `status` ends. Exit 0 completes, with warnings when the run
    /// printed a warning event (the bridge's rule, 2.6 S16), exit 125 is a cancel (2.7 E5), and
    /// any other status fails.
    public static func ofExit(_ status: Int32, warned: Bool) -> RouteParityEnd {
        switch status {
        case 0: return warned ? .completedWithWarnings : .completed
        case 125: return .cancelled
        default: return .failed
        }
    }
}

/// What a side reports once its run has ended.
public struct RouteParitySideOutcome: Sendable {
    public var end: RouteParityEnd
    /// What a reader of a failure needs, such as the row's error or the exit status.
    public var detail: String
    /// The command the side's row recorded. Side C must record one, and side C' replays it.
    public var recordedCommand: String?
    /// What the cancel of the side's CLI run observed, when `runCLI` cancelled it. A case that
    /// cancels checks it with S30's assertions (RouteParityHarness+Cancel.swift).
    public var cancel: RouteParityCancelObservation?

    public init(
        end: RouteParityEnd,
        detail: String = "",
        recordedCommand: String? = nil,
        cancel: RouteParityCancelObservation? = nil
    ) {
        self.end = end
        self.detail = detail
        self.recordedCommand = recordedCommand
        self.cancel = cancel
    }
}

/// One side's run.
public struct RouteParitySideRun: Sendable {
    public let side: RouteParitySide
    /// The side root, which held a copy of the fixture before the run.
    public let root: URL
    public let outcome: RouteParitySideOutcome
    /// The arguments after the binary of each line side C' ran, empty for the other sides.
    public let replayedArguments: [[String]]

    public init(side: RouteParitySide, root: URL, outcome: RouteParitySideOutcome, replayedArguments: [[String]] = []) {
        self.side = side
        self.root = root
        self.outcome = outcome
        self.replayedArguments = replayedArguments
    }
}

/// The three sides of one case.
public struct RouteParityRuns: Sendable {
    public let caseRoot: URL
    public let a: RouteParitySideRun
    public let c: RouteParitySideRun
    public let cPrime: RouteParitySideRun
    /// The SHA-256 of each file of the fixture by its relative name, read before any side ran.
    /// A side's facts leave out a file the fixture held as it is.
    public let fixture: [String: String]

    public init(
        caseRoot: URL,
        a: RouteParitySideRun,
        c: RouteParitySideRun,
        cPrime: RouteParitySideRun,
        fixture: [String: String] = [:]
    ) {
        self.caseRoot = caseRoot
        self.a = a
        self.c = c
        self.cPrime = cPrime
        self.fixture = fixture
    }

    public var all: [RouteParitySideRun] { [a, c, cPrime] }
}

/// What the harness found in one case: every difference by scope, and the lines that fail the
/// case against its declared list.
public struct RouteParityResult: Sendable {
    public let runs: RouteParityRuns
    public let found: [RouteParityScope: [RouteParityDifference]]
    public let failures: [String]
}

/// Runs a route parity case on sides A, C and C', compares them and checks the declared list.
public struct RouteParityHarness: Sendable {
    /// The built `lungfish-cli`, which side C launches and side C' replays with.
    public let cliBinary: URL
    /// What "the same result" means for the family's output (docs/contracts/CLI-EQUIVALENCE.md).
    public let kind: OutputEquivalence.Kind
    /// The contract's masks. A family adds one only through a reviewed change to the contract.
    public let masks: OutputEquivalence.MaskPolicy
    /// How long each line of side C' may run before the replay ends as failed.
    public let replayTimeout: Duration
    /// The variables each CLI run gets over the app's subprocess environment, from the side's
    /// root, such as the stand-in tools that answer both sides (panel G5). Side C' runs with
    /// them, and a side C that calls `runCLI` passes them too.
    public let environment: @Sendable (URL) -> [String: String]

    public init(
        cliBinary: URL,
        kind: OutputEquivalence.Kind,
        masks: OutputEquivalence.MaskPolicy = .standard,
        replayTimeout: Duration = .seconds(600),
        environment: @escaping @Sendable (URL) -> [String: String] = { _ in [:] }
    ) {
        self.cliBinary = cliBinary
        self.kind = kind
        self.masks = masks
        self.replayTimeout = replayTimeout
        self.environment = environment
    }

    /// The root of `side` in `caseRoot`.
    public static func root(of side: RouteParitySide, in caseRoot: URL) -> URL {
        caseRoot.appendingPathComponent(side.folderName, isDirectory: true)
    }

    // MARK: - Running the sides

    /// Builds the fixture in root A, copies root A to roots C and C' before any side runs, then
    /// runs side A, side C and side C', the replay of the command side C recorded. A side that
    /// throws ends the case with that error. `caseRoot` is removed first, so it must be a folder
    /// of the case's own, never the test's scratch root. With `cancel`, side C' is cancelled at
    /// its point, as side C's closure cancels side C.
    @MainActor
    public func run(
        in caseRoot: URL,
        cancel: RouteParityCancel? = nil,
        fixture: (URL) throws -> Void,
        sideA: (URL) async throws -> RouteParitySideOutcome,
        sideC: (URL) async throws -> RouteParitySideOutcome
    ) async throws -> RouteParityRuns {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: caseRoot)
        let rootA = Self.root(of: .a, in: caseRoot)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fixture(rootA)
        let fixtureDigests = Self.fixtureDigests(under: rootA)
        for side in [RouteParitySide.c, .cPrime] {
            try fileManager.copyItem(at: rootA, to: Self.root(of: side, in: caseRoot))
        }
        let runA = RouteParitySideRun(side: .a, root: rootA, outcome: try await sideA(rootA))
        let rootC = Self.root(of: .c, in: caseRoot)
        let runC = RouteParitySideRun(side: .c, root: rootC, outcome: try await sideC(rootC))
        let runCPrime = await replay(of: runC, in: Self.root(of: .cPrime, in: caseRoot), cancel: cancel)
        return RouteParityRuns(caseRoot: caseRoot, a: runA, c: runC, cPrime: runCPrime, fixture: fixtureDigests)
    }

    /// Side C'. The command `c` recorded, rebased from root C onto `root` and run line by line by
    /// the built CLI through the real transport, with `environment` for `root`, stopping at the
    /// first line that does not complete. With `cancel`, a line is cancelled once its point is
    /// reached. Side C' sees a warning the way side C's row does, as a `log` event at `warning`,
    /// which the CLI prints under `--format json`. A route records the argv it ran, that option
    /// included, so a line without it ends Completed where side C warned, and the detail says so.
    public func replay(of c: RouteParitySideRun, in root: URL, cancel: RouteParityCancel? = nil) async -> RouteParitySideRun {
        guard let command = c.outcome.recordedCommand else {
            let outcome = RouteParitySideOutcome(end: .failed, detail: "not run, side C recorded no command")
            return RouteParitySideRun(side: .cPrime, root: root, outcome: outcome)
        }
        var replayed: [[String]] = []
        do {
            let script = try Self.rebased(command, from: c.root, to: root)
            replayed = try script.components(separatedBy: "\n").map(Self.arguments(ofLine:))
        } catch {
            let outcome = RouteParitySideOutcome(end: .failed, detail: "not run, the recorded command does not rebase: \(error)")
            return RouteParitySideRun(side: .cPrime, root: root, outcome: outcome)
        }
        var isReached: (@Sendable () -> Bool)?
        if let cancel {
            isReached = { cancel.isReached(root) }
        }
        var warned = false
        for arguments in replayed {
            let run = await Self.runCLI(
                cliBinary, arguments: arguments, timeout: replayTimeout, environment: environment(root), cancelWhen: isReached
            )
            switch run.end {
            case .completed:
                continue
            case .completedWithWarnings:
                warned = true
            case .failed, .cancelled:
                let outcome = RouteParitySideOutcome(end: run.end, detail: run.detail, cancel: run.cancel)
                return RouteParitySideRun(side: .cPrime, root: root, outcome: outcome, replayedArguments: replayed)
            }
        }
        let silent = replayed.filter { !Self.printsEvents($0) }.count
        let detail = silent == 0 ? "exit 0" : "exit 0, \(silent) of \(replayed.count) lines without --format json, which print no warning event"
        let outcome = RouteParitySideOutcome(end: warned ? .completedWithWarnings : .completed, detail: detail)
        return RouteParitySideRun(side: .cPrime, root: root, outcome: outcome, replayedArguments: replayed)
    }

    /// Whether `arguments` ask the CLI for its JSON event lines.
    static func printsEvents(_ arguments: [String]) -> Bool {
        arguments.contains("--format=json") || zip(arguments, arguments.dropFirst()).contains { $0 == ("--format", "json") }
    }

    // MARK: - Checking a case

    /// Every difference `runs` holds and the lines that fail `parityCase` against `declared`. With
    /// a dump folder, `LUNGFISH_PARITY_DUMP` unless the caller names one, the case's roots and
    /// findings are copied there first.
    public func evaluate<Case: Hashable & Sendable>(
        _ parityCase: Case,
        declared: [RouteParityDeclaredDifference<Case>],
        runs: RouteParityRuns,
        dumpingTo dumpFolder: URL? = RouteParityHarness.dumpFolder
    ) throws -> RouteParityResult {
        let found = try differences(of: runs)
        let failures = Self.failures(found: found, parityCase: parityCase, declared: declared)
        if let dumpFolder {
            try Self.dump("\(parityCase)", runs: runs, found: found, failures: failures, in: dumpFolder)
        }
        return RouteParityResult(runs: runs, found: found, failures: failures)
    }

    /// Runs `parityCase` on its three sides in `caseRoot` and fails the test with every
    /// difference `declared` does not hold, and every entry whose count no longer holds. With
    /// `cancel`, sides C and C' must each have been cancelled through the real transport and pass
    /// S30's check (`assertCancelled`).
    @MainActor
    @discardableResult
    public func assertParity<Case: Hashable & Sendable>(
        _ parityCase: Case,
        declared: [RouteParityDeclaredDifference<Case>],
        in caseRoot: URL,
        cancel: RouteParityCancel? = nil,
        fixture: (URL) throws -> Void,
        sideA: (URL) async throws -> RouteParitySideOutcome,
        sideC: (URL) async throws -> RouteParitySideOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> RouteParityResult {
        let runs = try await run(in: caseRoot, cancel: cancel, fixture: fixture, sideA: sideA, sideC: sideC)
        let result = try evaluate(parityCase, declared: declared, runs: runs)
        Self.assertNoFailures(result.failures, in: "\(parityCase)", file: file, line: line)
        if let cancel {
            for side in [runs.c, runs.cPrime] {
                await Self.assertCancelled(side, cancel, file: file, line: line)
            }
        }
        return result
    }

    /// Fails the test once, listing every line of `failures`, when there is any.
    public static func assertNoFailures(
        _ failures: [String],
        in parityCase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !failures.isEmpty else { return }
        XCTFail("\(parityCase):\n" + failures.joined(separator: "\n"), file: file, line: line)
    }

    // MARK: - Dump

    /// `LUNGFISH_PARITY_DUMP`, the folder that keeps each case's roots and findings.
    public static var dumpFolder: URL? {
        ProcessInfo.processInfo.environment["LUNGFISH_PARITY_DUMP"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Copies the case root into the case's folder in `dumpFolder` and writes each side's end, the
    /// command side C recorded, the lines side C' ran and every difference and failure beside it.
    static func dump(
        _ parityCase: String,
        runs: RouteParityRuns,
        found: [RouteParityScope: [RouteParityDifference]],
        failures: [String],
        in dumpFolder: URL
    ) throws {
        let folder = dumpFolder.appendingPathComponent(parityCase, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: runs.caseRoot, to: folder)
        var report: [String] = []
        for run in runs.all {
            report.append("side \(run.side): \(run.outcome.end), \(run.outcome.detail)")
            if let command = run.outcome.recordedCommand { report.append("recorded command:\n\(command)") }
            report += run.replayedArguments.map { "replayed: \($0.joined(separator: " "))" }
        }
        for scope in RouteParityScope.all {
            let differences = found[scope] ?? []
            report.append("\(scope): \(differences.count)")
            report += differences.map { "  \($0)" }
        }
        report.append("failures: \(failures.count)")
        report += failures.map { "  \($0)" }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
