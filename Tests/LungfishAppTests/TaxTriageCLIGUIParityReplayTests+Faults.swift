// TaxTriageCLIGUIParityReplayTests+Faults.swift - The fault cases of the TaxTriage parity, X4 to X8
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Section 2.2 of the 2.9 QA inventory, the cases no real run gives on demand (ruling O5): a failed
// sample (X4), errored tasks the pipeline ignores (X5), a cancel once the engine runs (X6), the
// `--force` rebuild after the cleanup (X7) and the CLI's plain `--output` of two samples (X8). Each
// case sets the stand-in's behaviour. This file holds how a side is cancelled or rebuilt and the
// facts those ends hold on every side.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

extension TaxTriageParityCase {
    /// How every side of a case ends, in the words of a row.
    enum End: String, Sendable {
        case completed = "Completed"
        case completedWithWarnings = "Completed with Warnings"
        case cancelled = "Cancelled"
    }

    var expectedEnd: End {
        switch self {
        case .x4, .x5: return .completedWithWarnings
        case .x6: return .cancelled
        case .x1, .x2, .x3, .x7, .x8: return .completed
        }
    }

    /// The samples whose launch fails, X4's negative control.
    var failingSamples: Set<String> { self == .x4 ? ["negative-control"] : [] }

    /// The errored tasks the run of each sample ignores, X5's one MINIMAP2_ALIGN task.
    var ignoredFailuresPerSample: Int { self == .x5 ? 1 : 0 }

    /// What the stand-in Nextflow does in the case.
    var behaviour: TaxTriageStandInEngine.Behaviour {
        switch self {
        case .x4: return .failsSamples(failingSamples)
        case .x5: return .reportsErroredTasks
        case .x6: return .waitsUntilCancelled
        case .x1, .x2, .x3, .x7, .x8: return .completes
        }
    }

    /// Whether each side is cancelled once its engine runs.
    var cancelsOnceTheEngineStarts: Bool { self == .x6 }

    /// Whether each side's result is rebuilt with `build-db taxtriage --force` after the cleanup.
    var rebuildsAfterTheCleanup: Bool { self == .x7 }

    /// Whether the stand-in's organism report lists organisms. X7's lists none, so build-db takes
    /// the sample's rows from `top/` alone, the folder its cleanup deletes (2.8 row 258).
    var organismReportsHaveRows: Bool { self != .x7 }

    /// The organisms `taxtriage.sqlite` lists for each sample on the stand-in: the five of its
    /// 3.3.8 organism report, or the 31 of its top report where the organism report lists none.
    var standInOrganisms: Int { organismReportsHaveRows ? 5 : 31 }

    /// Whether side A runs. No GUI route makes X8's plain `--output` run of several samples.
    var runsGUISide: Bool { self != .x8 }

    /// The bundles no side may write into, every bundle of a cancelled request (T10) and the
    /// bundle of a failed sample.
    var untouchedBundlePaths: [String] {
        if expectedEnd == .cancelled { return bundlePaths }
        return bundlePaths.filter { failingSamples.contains(TaxTriageParitySampleFacts.forBundle($0).sampleID) }
    }

    /// The samples whose plan a pooled record keeps by sample id (T7), those whose read set plan
    /// says something.
    var keyedPlanSamples: [String] { self == .x8 ? ["merge"] : [] }
}

/// How one `build-db taxtriage` run ended.
enum TaxTriageParityBuild: Equatable, Sendable, CustomStringConvertible {
    case completed
    case failed(String)

    var description: String {
        switch self {
        case .completed: return "completed"
        case .failed(let message): return "failed, \(message)"
        }
    }
}

/// What X7's rebuild did to one side's result.
struct TaxTriageParityRebuild: Sendable, CustomStringConvertible {
    /// The app's own build on a side whose run built no database, nil where the run built one.
    let firstBuild: TaxTriageParityBuild?
    /// The SHA-256 of `taxtriage.sqlite` before the rebuild, nil when there was none.
    let databaseBefore: String?
    /// Whether `top/` was there when the rebuild started.
    let topBefore: Bool
    let outcome: TaxTriageParityBuild
    let databaseAfter: String?

    var description: String {
        "first build \(firstBuild.map(String.init(describing:)) ?? "none"), top/ \(topBefore ? "kept" : "gone"), "
            + "rebuild \(outcome), database \(databaseBefore == databaseAfter ? "kept" : "changed")"
    }
}

extension TaxTriageParityHarness {
    // MARK: - Cancel and rebuild

    /// Side B's cancel. The window's Cancel sends SIGTERM to `lungfish-cli`, and `taxtriage run`
    /// turns it into a cancel of its pipeline and exits 125 (2.9 S11). Side B runs the command in
    /// this process, so once the engine runs the signal goes to this process, where the
    /// command's own handler takes it. SIGTERM is ignored around the replay, so a command that no
    /// longer listens leaves the signal ignored and the case fails on its end, while the test
    /// process lives on. The stand-in's maximumWait bounds such a replay, not the engine's wait.
    /// A second SIGTERM while the command listens ends this process (`secondSignalEndsProcess`
    /// in TaxTriageCommand+Cancellation.swift), so the case sends exactly one.
    nonisolated static func replayTerminalCancelledBySIGTERM(
        of script: String,
        engine: TaxTriageParityEngine,
        launchesBefore: Int
    ) async -> TaxTriageParityTerminal {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let replay = Task { await Self.replayTerminal(of: script, engine: engine) }
        if await engine.standIn?.waitForLaunch(launchesBefore, timeout: engine.processWait) != nil {
            kill(getpid(), SIGTERM)
        }
        return await replay.value
    }

    /// X7. Runs `lungfish-cli build-db taxtriage <analysis> --force` through the built CLI as the
    /// app runs it after a TaxTriage run, first on a side whose run built no database, so the
    /// cleanup has run on every side, then once more, the rebuild of 2.8 row 258.
    func rebuildAfterTheCleanup(_ run: TaxTriageParitySideRun) async -> TaxTriageParitySideRun {
        guard let analysis = run.analysisFolder else { return run }
        let fileManager = FileManager.default
        let database = analysis.appendingPathComponent("taxtriage.sqlite")
        var firstBuild: TaxTriageParityBuild?
        if !fileManager.fileExists(atPath: database.path) {
            firstBuild = await Self.buildDatabase(in: analysis)
        }
        let before = try? ClassifierParityFixtures.sha256(of: database)
        let topBefore = fileManager.fileExists(atPath: analysis.appendingPathComponent("top").path)
        let outcome = await Self.buildDatabase(in: analysis)
        var rebuilt = run
        rebuilt.rebuild = TaxTriageParityRebuild(
            firstBuild: firstBuild,
            databaseBefore: before,
            topBefore: topBefore,
            outcome: outcome,
            databaseAfter: try? ClassifierParityFixtures.sha256(of: database)
        )
        return rebuilt
    }

    /// How `lungfish-cli build-db taxtriage <analysis> --force` ends through the built CLI, the
    /// app's own call (`LungfishCLIRunner.buildClassifierDatabase`).
    nonisolated static func buildDatabase(in analysis: URL) async -> TaxTriageParityBuild {
        do {
            try await LungfishCLIRunner.buildClassifierDatabase(tool: "taxtriage", resultURL: analysis, force: true)
            return .completed
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - Facts of every end

    /// No process of a stand-in launch outlives the side's run (QA checklist 2).
    func leftoverProcessViolations(run: TaxTriageParitySideRun, violate: (String, String) -> Void) {
        for launch in run.launches {
            guard let engineID = launch.processIdentifier else {
                violate("the stand-in records the process of each launch", "launch \(launch.folder.lastPathComponent) has no pid")
                continue
            }
            let alive = [engineID, launch.childProcessIdentifier].compactMap { $0 }.filter(Self.isRunning)
            if !alive.isEmpty {
                violate("no stand-in process outlives the run", "launch \(launch.folder.lastPathComponent) leaves \(alive) running")
            }
        }
    }

    /// The bundles of `untouchedBundlePaths` keep the pristine project's bytes, so a cancelled run
    /// and a failed sample write nothing into a source bundle (T10, QA inventory 2.2).
    func untouchedBundleViolations(
        _ parityCase: TaxTriageParityCase,
        run: TaxTriageParitySideRun,
        pristineProject: URL,
        violate: (String, String) -> Void
    ) {
        for path in parityCase.untouchedBundlePaths {
            let before = Self.bundleContents(pristineProject.appendingPathComponent(path, isDirectory: true))
            let after = Self.bundleContents(run.project.appendingPathComponent(path, isDirectory: true))
            let sampleID = TaxTriageParitySampleFacts.forBundle(path).sampleID
            // One difference per file, so a declared write cannot hide a second one.
            for file in Set(before.keys).union(after.keys).filter({ before[$0] != after[$0] }).sorted() {
                let change = before[file] == nil ? "added" : (after[file] == nil ? "removed" : "changed")
                violate("nothing is written into \(sampleID)'s bundle: \(file)", change)
            }
        }
    }

    /// Every regular file below `bundle`, hidden ones included, by its path in the bundle, with
    /// its SHA-256.
    static func bundleContents(_ bundle: URL) -> [String: String] {
        let base = bundle.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var contents: [String: String] = [:]
        while let item = enumerator.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            contents[path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path] =
                (try? ClassifierParityFixtures.sha256(of: item)) ?? "unreadable"
        }
        return contents
    }

    // MARK: - Facts of one end

    /// X6 on every side: the row reads Cancelled by user with no alert and no warning, or the
    /// command exits 125 (E5, 2.9 S11), the folder keeps a record that says cancelled with exit
    /// 125, and no result is written (T10).
    func cancelledViolations(run: TaxTriageParitySideRun, violate: (String, String) -> Void) {
        switch run.terminal {
        case .row("Cancelled"), .exit(125):
            break
        default:
            violate("the cancel ends the row as Cancelled and the command with exit 125", "\(run.terminal)")
        }
        if let row = run.row,
           row.completionDetail != "Cancelled by user" || row.alertText != nil || row.logLines.contains(where: { $0.hasPrefix("[warning]") }) {
            violate("the cancelled row reads Cancelled by user with no alert and no warning", "\(row.completionDetail), alert \(row.alertText ?? "none"), \(row.logLines)")
        }
        guard let analysis = run.analysisFolder, FileManager.default.fileExists(atPath: analysis.path) else {
            violate("the cancelled run keeps its folder", "\(run.analysisPath ?? "no folder")")
            return
        }
        let record = try? ProvenanceEnvelopeReader.load(from: analysis)
        if record?.status != .cancelled || record?.exitStatus != 125 {
            violate("the record says cancelled with exit 125", "\(record.map { "\($0.status) \($0.exitStatus.map(String.init) ?? "none")" } ?? "no record")")
        }
        if FileManager.default.fileExists(atPath: analysis.appendingPathComponent("taxtriage-result.json").path) {
            violate("a cancelled run writes no result", "taxtriage-result.json in \(analysis.lastPathComponent)")
        }
    }

    /// X7 on every side, today's rebuild after the cleanup (2.8 row 258). The cleanup deleted
    /// `top/`, where the sample's only rows came from, so the `--force` rebuild of the single
    /// result fails and keeps the database it had. On a side whose run keeps `top/` (sides C and
    /// C', the executor's finalize of 2.8 T5), the run built the database and the rebuild
    /// completes.
    func rebuildViolations(run: TaxTriageParitySideRun, keepsTop: Bool, violate: (String, String) -> Void) {
        guard let rebuild = run.rebuild else {
            violate("the result is rebuilt after the cleanup", "no rebuild ran")
            return
        }
        if let firstBuild = rebuild.firstBuild, firstBuild != .completed {
            violate("the app's build-db builds the database first", "\(firstBuild)")
        }
        if keepsTop {
            if rebuild.firstBuild != nil || !rebuild.topBefore || rebuild.outcome != .completed {
                violate("the run builds the database, its cleanup keeps top/ and the --force rebuild completes", "\(rebuild)")
            }
            return
        }
        if rebuild.topBefore {
            violate("the cleanup deleted top/ before the rebuild", "\(rebuild)")
        }
        if rebuild.outcome == .completed || rebuild.databaseBefore == nil || rebuild.databaseAfter != rebuild.databaseBefore {
            violate("the --force rebuild after the cleanup fails and keeps the database", "\(rebuild)")
        }
    }

    /// X8 on every side that runs it: the help of `taxtriage run` names the pooled run of several
    /// samples (T2), and the pooled record keeps each sample's plan by sample id (T7).
    func pooledRequestViolations(
        _ parityCase: TaxTriageParityCase,
        analysis: URL,
        violate: (String, String) -> Void
    ) {
        let help = TaxTriageCommand.RunSubcommand.helpMessage(columns: 1000)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let sentence = "Without --project or --batch, one Nextflow run processes every sample"
        if !help.contains(sentence) {
            violate("the help of taxtriage run names the pooled run", "no \"\(sentence)\" in the help")
        }
        let record = try? ProvenanceEnvelopeReader.load(from: analysis)
        let keyed = record?.options.explicit["read_set_plans"]?.dictionaryValue.map { $0.keys.sorted() }
        if keyed ?? [] != parityCase.keyedPlanSamples {
            violate("the pooled record keeps each sample's plan by sample id", "read_set_plans \(keyed.map(String.init(describing:)) ?? "absent")")
        }
    }

    /// Whether `pid` names a process that has not exited. A zombie only waits to be reaped, so it
    /// has exited.
    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) != SZOMB
    }
}

extension TaxTriageCLIGUIParityReplayTests {
    /// Cuts the case engine's organism report fixture to its header, so each report the stand-in
    /// writes lists no organism and build-db takes the sample's rows from `top/` alone (X7). The
    /// stand-in copies `fixtures/odr.txt` of its root into `report/<sample>.odr.txt` at each
    /// launch. A stand-in that keeps the fixture elsewhere fails the case here (a note for Q9).
    static func emptyOrganismReport(of engine: TaxTriageStandInEngine) throws {
        let fixture = engine.root.appendingPathComponent("fixtures/odr.txt")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw ParityError.noOrganismReportFixture(fixture.path)
        }
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let header = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        try (header + "\n").write(to: fixture, atomically: true, encoding: .utf8)
    }
}
