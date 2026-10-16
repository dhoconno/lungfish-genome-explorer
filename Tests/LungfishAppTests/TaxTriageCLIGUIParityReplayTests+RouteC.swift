// TaxTriageCLIGUIParityReplayTests+RouteC.swift - Sides C and C' of a TaxTriage parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1b, a rider of A2, with 2.7 T2 and 2.8 T1, T2, T4, T5 and T17. Since Phase 2.11
// lane U30 M3 side C is the GUI route the hidden key's `cli` value selects, `launchTaxTriage(route: .cli)`,
// which runs `taxtriage run --project` with the inputs and settings of the wizard's config through the
// built `lungfish-cli` on the case's engine, with its Operations panel row (runGUISide). Side C' reads
// the argv side C's root record names, rebases it onto its own root and runs it through the same
// binary. C against C' checks that the recorded command gives the same result and declares
// nothing (the acceptance of 2.7 T2). A against C declares what the switch of the route changes,
// a list that may only shrink.
//
// - One sample runs `--project` in place of side A's `--output`, so the run lays out its own
//   `Analyses/taxtriage-batch-<timestamp>/` (T4), and its finalize builds `taxtriage.sqlite` and
//   records the cleanup that keeps `top/` (T5).
// - Several samples run one `--input` per bundle with `--project` and `--batch`, one Nextflow per
//   sample (T2), and the row records that command (X3 and X4). X8, which no GUI route makes, keeps
//   side B's plain `--output` through the built binary, one Nextflow for both samples (T2, T7).
// - A cancel (X6) is the row's Cancel, which the transport sends as SIGTERM to the CLI's process
//   tree with the grace the app gives it (`CLIProcessLauncher.operationGrace`) once the engine runs.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

extension TaxTriageParityCase {
    /// Whether `side` runs every sample of the request in one Nextflow: side B's pooled command
    /// of several samples, and on sides C and C' only X8's plain `--output` (2.8 T2).
    func runsPooled(on side: TaxTriageParitySide) -> Bool {
        switch side {
        case .a: return false
        case .b: return pooledInputFolder != nil
        case .c, .cPrime: return self == .x8
        }
    }

    /// Whether `side`'s result keeps `top/` through every build-db taxtriage, a `taxtriage run` result
    /// of one Nextflow per sample. On sides C and C' the executor's finalize of a `--project` result
    /// builds `taxtriage.sqlite` with the cleanup that keeps `top/` (2.8 T5 and row 258). Side B's
    /// plain `--output` builds none, and since B30's review fix 8 the app's first build-db of it runs
    /// that cleanup too.
    func keepsTop(on side: TaxTriageParitySide) -> Bool {
        side != .a && !runsPooled(on: side)
    }
}

/// Side C's root record names no argv that the built `lungfish-cli` ran.
struct TaxTriageParityRecordedArgvError: Error, CustomStringConvertible {
    let argv: [String]

    var description: String { "side C's root record names no lungfish-cli argv: \(argv)" }
}

extension TaxTriageParityHarness {
    /// The `lungfish-cli` that side C's route launches. The app's transport gives the CLI the app's
    /// subprocess environment, which names this Mac's managed tool root, so on a stand-in engine it
    /// launches a script that exports the engine's `cliEnvironment` and then execs the built binary,
    /// whose own argv the root record names. A managed engine adds nothing, so the built binary runs
    /// as the app runs it.
    func cliRouteExecutable(engine: TaxTriageParityEngine) throws -> URL {
        guard !engine.cliEnvironment.isEmpty else { return cliBinary }
        if let storage = engine.cliEnvironment["LUNGFISH_STORAGE_ROOT"] {
            try FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)
        }
        let script = engine.root.appendingPathComponent("cli-route", isDirectory: true)
            .appendingPathComponent(CLICommandIdentity.executableName)
        let exports = engine.cliEnvironment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Self.shellQuoted($0.value))" }
        let text = (["#!/bin/sh"] + exports + ["exec \(Self.shellQuoted(cliBinary.path)) \"$@\""]).joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// `value` in single quotes for a POSIX shell.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Side C of X8, which no GUI route makes. The routed command of the case's request
    /// (`routedCommand`), run by the built `lungfish-cli` on the engine.
    func runRoutedSide(
        _ parityCase: TaxTriageParityCase,
        root: URL,
        engine: TaxTriageParityEngine
    ) async -> TaxTriageParitySideRun {
        do {
            return await runBinary(.c, try routedCommand(parityCase, root: root, engine: engine), parityCase, root: root, engine: engine)
        } catch {
            return Self.failedBeforeRunning(.c, root: root, error: error)
        }
    }

    /// Side C'. The argv side C's root record names, rebased onto `root` and run by the built
    /// `lungfish-cli` that side C ran. A side C that keeps no record leaves C' not run, which the
    /// comparison of C against C' reports.
    func runRecordedArgv(
        of routed: TaxTriageParitySideRun,
        _ parityCase: TaxTriageParityCase,
        root: URL,
        engine: TaxTriageParityEngine
    ) async -> TaxTriageParitySideRun {
        guard let analysis = routed.analysisFolder, let record = try? ProvenanceEnvelopeReader.load(from: analysis) else {
            return .notRun(.cPrime, root: root, reason: "side C keeps no root record")
        }
        do {
            guard let binary = record.argv.first,
                  (binary as NSString).lastPathComponent == CLICommandIdentity.executableName else {
                throw TaxTriageParityRecordedArgvError(argv: record.argv)
            }
            let command = OperationCenter.buildCLICommand(subcommand: "", args: Array(record.argv.dropFirst()))
            let words = try RecordedCLICommand.arguments(of: RecordedCLICommand.rebased(command, from: routed.root, to: root))
            return await runBinary(.cPrime, words, parityCase, root: root, engine: engine)
        } catch {
            return Self.failedBeforeRunning(.cPrime, root: root, error: error)
        }
    }

    /// The words of side C's command after `lungfish-cli`. They are the words the row of one
    /// sample records, with the samples' folder as the one `--input` and no `--sample` for
    /// several, as side B's pooled command, and `--project` in place of `--output`, so the run
    /// lays out its folder as the app does (2.8 T4 and T17), and the `run` subcommand the CLI
    /// route spells. X8 keeps its plain `--output` into the folder side B writes (2.8 T2).
    func routedCommand(
        _ parityCase: TaxTriageParityCase,
        root: URL,
        engine: TaxTriageParityEngine
    ) throws -> [String] {
        let project = root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true)
        var config = parityCase.wizardConfig(project: project, engine: engine)
        if let folder = parityCase.pooledInputFolder {
            config.samples = [TaxTriageSample(
                sampleId: "pooled",
                fastq1: project.appendingPathComponent(folder, isDirectory: true),
                platform: config.platform
            )]
        }
        config.outputDirectory = project.appendingPathComponent("Analyses/taxtriage-pooled", isDirectory: true)
        var words = try RecordedCLICommand.arguments(of: AppDelegate.taxTriageCLICommand(for: config))
        if parityCase.pooledInputFolder != nil, let index = words.firstIndex(of: "--sample"), index + 1 < words.count {
            words.removeSubrange(index...(index + 1))
        }
        guard !parityCase.runsPooled(on: .c) else { return words }
        guard let index = words.firstIndex(of: "--output"), index + 1 < words.count else {
            throw TaxTriageParityPooledCommandError(words: words)
        }
        words.replaceSubrange(index...(index + 1), with: ["--project", project.path])
        // The route runs `taxtriage run --project` (`ClassifierCLIRouteLaunch.taxTriage`), so the command the
        // live class runs spells the subcommand as the route does. A fact pins the two to the same words (the
        // review of U30 M3, fix 5).
        if words.first == "taxtriage", words.dropFirst().first != "run" {
            words.insert("run", at: 1)
        }
        return words
    }

    /// Runs `words` with the built `lungfish-cli` in `root` and reads what it left. A line with
    /// `--project` names no folder, so its folder is the one the run made in the project's
    /// `Analyses/`.
    private func runBinary(
        _ side: TaxTriageParitySide,
        _ words: [String],
        _ parityCase: TaxTriageParityCase,
        root: URL,
        engine: TaxTriageParityEngine
    ) async -> TaxTriageParitySideRun {
        let analyses = root.appendingPathComponent("\(ClassifierParityFixtures.projectName)/Analyses", isDirectory: true)
        let before = Set(Self.visibleFolders(in: analyses))
        let launchesBefore = (try? engine.launches().count) ?? 0
        let terminal = await binaryTerminal(of: words, parityCase, engine: engine, launchesBefore: launchesBefore)
        let made = Self.visibleFolders(in: analyses).filter { !before.contains($0) }
        var folder = TaxTriageParityReplayedCommand.outputFolder(in: words)
        if folder.isEmpty, made.count == 1 {
            folder = analyses.appendingPathComponent(made[0], isDirectory: true).path
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let written = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
        let analysisPath = folder.isEmpty || !written.hasPrefix(base)
            ? nil
            : String(written.dropFirst(base.count)).split(separator: "/").prefix(3).joined(separator: "/")
        return TaxTriageParitySideRun(
            side: side,
            root: root,
            analysisPath: analysisPath,
            recordedCommand: nil,
            replayedCommands: [TaxTriageParityReplayedCommand(outputFolder: folder, argv: [cliBinary.path] + words)],
            terminal: terminal,
            row: nil,
            launches: Array(((try? engine.launches()) ?? []).dropFirst(launchesBefore))
        )
    }

    /// How the built `lungfish-cli` ends with `words` on the engine, raced against the engine's
    /// wait. A case that cancels sends the transport's cancel once the engine has started, with
    /// the grace the app gives `taxtriage run` (8 s), and the CLI's own exit stands, 125 after a
    /// cancel (2.9 S2). A run that outlives the wait is cancelled and ends as an error.
    private func binaryTerminal(
        of words: [String],
        _ parityCase: TaxTriageParityCase,
        engine: TaxTriageParityEngine,
        launchesBefore: Int
    ) async -> TaxTriageParityTerminal {
        var spec = CLIProcessLauncher.spec(
            executableURL: cliBinary,
            arguments: words,
            standardOutput: .captured,
            terminationGracePeriod: .seconds(8)
        )
        spec.environment.merge(engine.cliEnvironment) { _, engineValue in engineValue }
        if let storage = engine.cliEnvironment["LUNGFISH_STORAGE_ROOT"] {
            try? FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)
        }
        let cancellation = CLIRunCancellation()
        let timeout = engine.processWait
        let standIn = engine.standIn
        let cancels = parityCase.cancelsOnceTheEngineStarts
        let launcherSpec = spec
        return await withTaskGroup(of: TaxTriageParityTerminal?.self) { group in
            group.addTask {
                Self.terminal(of: await CLIProcessLauncher.run(launcherSpec, cancellation: cancellation))
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : .error("timed out after \(timeout)")
            }
            if cancels {
                group.addTask {
                    if await standIn?.waitForLaunch(launchesBefore, timeout: timeout) != nil {
                        cancellation.cancel()
                    }
                    return nil
                }
            }
            var first: TaxTriageParityTerminal?
            while first == nil, let next = await group.next() {
                first = next
            }
            if case .error(let message)? = first, message.hasPrefix("timed out") {
                cancellation.cancel()
            }
            group.cancelAll()
            return first ?? .error("the CLI returned nothing")
        }
    }

    /// A CLI outcome as a side's end. A cancelled run keeps the CLI's own exit status, and a run
    /// that failed keeps its standard error in the test log.
    nonisolated static func terminal(of outcome: CLIProcessOutcome) -> TaxTriageParityTerminal {
        switch outcome {
        case .exited(let exit), .cancelled(let exit?):
            if exit.status != 0 {
                print("lungfish-cli exited \(exit.status): \(exit.failureDetail.suffix(2000))")
            }
            return .exit(exit.status)
        case .cancelled(nil):
            return .error("cancelled before lungfish-cli ran")
        case .launchFailed(let reason):
            return .error("lungfish-cli did not launch: \(reason)")
        }
    }

    /// A side whose command could not be built.
    static func failedBeforeRunning(_ side: TaxTriageParitySide, root: URL, error: Error) -> TaxTriageParitySideRun {
        TaxTriageParitySideRun(
            side: side, root: root, analysisPath: nil, recordedCommand: nil, replayedCommands: [],
            terminal: .error(String(describing: error)), row: nil, launches: []
        )
    }
}
