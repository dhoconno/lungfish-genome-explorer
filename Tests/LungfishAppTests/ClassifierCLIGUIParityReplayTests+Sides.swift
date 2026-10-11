// ClassifierCLIGUIParityReplayTests+Sides.swift - The parity cases and the runs of their four sides
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Side A drives today's GUI path through `AppDelegate` on `OperationCenter.shared`, with the
// configs the wizards build. Side C hands the same configs to the launch the FASTQ operations
// dialog calls, with every route key set to the CLI route, so the run goes through
// `CLIClassifierRunner` and the built `lungfish-cli` that `LUNGFISH_CLI_PATH` names. Side B rebases
// the command side A's row recorded onto a fresh root and runs it in this process. Side C' rebases
// side C's and runs it with the same built `lungfish-cli` (panel decision T2).

import AppKit
import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// The cases of panel decisions T2 and T3 and memo BIO O7.
enum ClassifierParityCase: String, CaseIterable, Sendable {
    /// Kraken2, classification only, on the golden's virtual subset bundle.
    case k1 = "K1"
    /// The wizard's Kraken2 request on the merge bundle, so a read-set plan is recorded.
    case k2 = "K2"
    /// The wizard's Kraken2 request on the subset bundle and the merge bundle as one batch.
    case k3 = "K3"
    /// The wizard's Kraken2 request on the subset bundle, a real Bracken species profile.
    case k4 = "K4"
    /// The wizard's Kraken2 request on the negative control, with no viral hit.
    case k5 = "K5"
    /// The wizard's Kraken2 request on the low-signal control, five SARS-CoV-2 reads among the
    /// 40 of the negative control, too few for Bracken's threshold (F2 bio ruling 1, lane A8).
    case k6 = "K6"
    /// EsViritu on the subset bundle.
    case e1 = "E1"
    /// EsViritu on the SARS-CoV-2 pair.
    case e2 = "E2"
    /// EsViritu on the subset bundle and the pair as one batch.
    case e3 = "E3"

    enum Tool: Sendable {
        case kraken2
        case esViritu
    }

    var tool: Tool {
        switch self {
        case .e1, .e2, .e3: return .esViritu
        case .k1, .k2, .k3, .k4, .k5, .k6: return .kraken2
        }
    }

    /// The bundles the wizard is given, relative to the project.
    var bundlePaths: [String] {
        switch self {
        case .k1, .k4, .e1: return [ClassifierParityFixtures.subsetBundlePath]
        case .k2: return [ClassifierParityFixtures.mergeBundlePath]
        case .k3: return [ClassifierParityFixtures.subsetBundlePath, ClassifierParityFixtures.mergeBundlePath]
        case .k5: return [ClassifierParityFixtures.negativeControlBundlePath]
        case .k6: return [ClassifierParityFixtures.lowSignalControlBundlePath]
        case .e2: return [ClassifierParityFixtures.pairBundlePath]
        case .e3: return [ClassifierParityFixtures.subsetBundlePath, ClassifierParityFixtures.pairBundlePath]
        }
    }

    var isBatch: Bool { bundlePaths.count > 1 }

    /// Whether Bracken runs. The wizard always asks for a profile, and K1 asks for the
    /// classification alone, the `.classify` goal `runClassification` also runs.
    var profiles: Bool { tool == .kraken2 && self != .k1 }

    /// How long side A's row and side B's replay may each take. Each wait ends as soon as its
    /// run finishes.
    var timeout: Duration { isBatch ? .seconds(2_400) : .seconds(1_200) }

    /// The wizard's run token, eight characters of a UUID, fixed here. The launch replaces the
    /// folder it names with one under `Analyses/`.
    static let runToken = "0000PAR1"

    /// The configs `ClassificationWizardSheet.performRun` builds for the case's bundles, with
    /// the Stable Viral database, the balanced preset and one thread.
    @MainActor
    func kraken2Configs(project: URL) async throws -> [ClassificationConfig] {
        let bundles = bundlePaths.map { project.appendingPathComponent($0, isDirectory: true) }
        let registered = try await MetagenomicsDatabaseRegistry.shared.database(named: "Viral")
        let database = try XCTUnwrap(registered, "no Viral database")
        let databasePath = try XCTUnwrap(database.path, "the Viral database has no path")
        let baseDirectory = bundles[0].deletingLastPathComponent()
        let batchRoot = baseDirectory.appendingPathComponent("classification-batch-\(Self.runToken)")
        var configs: [ClassificationConfig] = []
        for sample in MetagenomicsSampleGrouper.group(bundles) {
            let outputDirectory = isBatch
                ? batchRoot.appendingPathComponent(MetagenomicsSampleGrouper.sanitizeSampleId(sample.sampleId))
                : baseDirectory.appendingPathComponent("classification-\(Self.runToken)")
            let plan = await ClassificationSampleReadPlan.planned(for: sample)
            let config = ClassificationWizardSheet.makeProfileConfig(
                sample: sample,
                readPlan: plan,
                database: database,
                databasePath: databasePath,
                outputDirectory: outputDirectory,
                confidence: ClassificationConfig.Preset.balanced.parameters.confidence,
                minimumHitGroups: ClassificationConfig.Preset.balanced.parameters.minimumHitGroups,
                threads: 1,
                memoryMapping: false,
                extraArguments: []
            )
            configs.append(profiles ? config : Self.classificationOnly(config))
        }
        return configs
    }

    /// The wizard's config with the `.classify` goal and no Bracken request.
    private static func classificationOnly(_ config: ClassificationConfig) -> ClassificationConfig {
        var classify = ClassificationConfig(
            goal: .classify,
            inputFiles: config.inputFiles,
            isPairedEnd: config.isPairedEnd,
            interleavedInput: config.interleavedInput,
            inputLayout: config.inputLayout,
            databaseName: config.databaseName,
            databaseVersion: config.databaseVersion,
            databasePath: config.databasePath,
            databaseDigest: config.databaseDigest,
            databaseCatalogID: config.databaseCatalogID,
            databaseInstallationRecipe: config.databaseInstallationRecipe,
            brackenProfileRequest: nil,
            confidence: config.confidence,
            minimumHitGroups: config.minimumHitGroups,
            threads: config.threads,
            memoryMapping: config.memoryMapping,
            quickMode: config.quickMode,
            outputDirectory: config.outputDirectory,
            extraArguments: config.extraArguments
        )
        classify.plansReadSet = config.plansReadSet
        return classify
    }

    /// The configs `EsVirituWizardSheet.performRun` builds for the case's bundles, with the
    /// quality filter on, one thread and `database` resolved as the wizard resolves it.
    @MainActor
    func esVirituConfigs(project: URL, database: URL) async -> [EsVirituConfig] {
        let bundles = bundlePaths.map { project.appendingPathComponent($0, isDirectory: true) }
        let baseDirectory = bundles[0].deletingLastPathComponent()
        let batchRoot = baseDirectory.appendingPathComponent("esviritu-batch-\(Self.runToken)")
        var configs: [EsVirituConfig] = []
        for sample in MetagenomicsSampleGrouper.group(bundles) {
            let outputDirectory = isBatch
                ? batchRoot.appendingPathComponent(MetagenomicsSampleGrouper.sanitizeSampleId(sample.sampleId))
                : baseDirectory.appendingPathComponent("esviritu-\(Self.runToken)")
            let plan = await EsVirituSampleReadPlan.planned(for: sample)
            var config = EsVirituConfig(
                inputFiles: sample.inputFiles,
                isPairedEnd: sample.isPairedEnd,
                sampleName: sample.sampleId,
                outputDirectory: outputDirectory,
                databasePath: database,
                qualityFilter: true,
                threads: 1,
                extraArguments: [],
                readFormat: plan.format,
                inputLayout: plan.layout
            )
            config.plansReadSet = plan.plansReadSet
            configs.append(config)
        }
        return configs
    }
}

/// The sides of a parity case (panel decision T2).
enum ClassifierParitySide: String, CaseIterable, Sendable, CustomStringConvertible {
    /// Today's GUI path through `AppDelegate`, run serially on `OperationCenter.shared`.
    case a = "A"
    /// The command side A's row recorded, rebased onto a fresh root and run in this process.
    case b = "B"
    /// The GUI route through `lungfish-cli` (lane A10), run serially on `OperationCenter.shared`.
    case c = "C"
    /// The command side C's row recorded, rebased onto a fresh root and run by the built
    /// `lungfish-cli` that side C ran.
    case cPrime = "C'"

    var description: String { rawValue }

    /// The folder of the side's root, a name a recorded command needs no quote for.
    var folderName: String {
        self == .cPrime ? "C-prime" : rawValue
    }

    /// Whether the side runs a GUI route and so has an Operations panel row.
    var hasRow: Bool {
        self == .a || self == .c
    }
}

/// How a side's run ended.
enum ClassifierParityTerminal: Equatable, Sendable, CustomStringConvertible {
    /// The final state label of an Operations panel row, such as "Completed with Warnings".
    case row(String)
    /// The exit status of a replayed command, 0 when it returned.
    case exit(Int32)
    /// A replayed command threw something other than an exit status.
    case error(String)
    /// No command ran, for the reason given.
    case notRun(String)

    /// Whether the run kept its result: a completed row, with or without warnings, or exit 0.
    var succeeded: Bool {
        switch self {
        case .row(let label): return label.hasPrefix("Completed")
        case .exit(let status): return status == 0
        case .error, .notRun: return false
        }
    }

    var description: String {
        switch self {
        case .row(let label): return "row \(label)"
        case .exit(let status): return "exit \(status)"
        case .error(let message): return "error \(message)"
        case .notRun(let reason): return "not run, \(reason)"
        }
    }
}

/// One command line a replay ran, with the argv the shipped binary would have recorded.
struct ClassifierParityReplayedCommand: Sendable {
    /// The folder the line writes, the value of `--output-dir` or `--output`.
    let outputFolder: String
    /// The built `lungfish-cli` path followed by the line's arguments.
    let argv: [String]

    static func outputFolder(in arguments: [String]) -> String {
        for option in ["--output-dir", "--output", "-o"] {
            if let index = arguments.firstIndex(of: option), index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return ""
    }
}

/// The Operations panel row of a GUI run (UX memo T2): what a user reads.
struct ClassifierParityRowOutcome: Equatable, Sendable {
    struct LogLine: Equatable, Sendable, CustomStringConvertible {
        let level: String
        let message: String
        var description: String { "[\(level)] \(message)" }
    }

    let title: String
    let firstDetail: String
    let stateLabel: String
    let completionDetail: String
    let errorMessage: String?
    /// The text of the alert sheet the run left on the viewer's window, nil for none.
    let alertText: String?
    let logLines: [LogLine]
    /// Every detail the row showed while it ran, in order, the first detail first.
    let details: [String]
    /// Every line the viewer's progress overlay showed, in order.
    let overlayLines: [String]
}

/// What one side's run left for the comparisons.
struct ClassifierParitySideRun {
    let side: ClassifierParitySide
    let root: URL
    /// The analysis folder relative to `root`, nil when the run made none.
    let analysisPath: String?
    /// The command the side's row recorded, for a GUI side.
    let recordedCommand: String?
    /// The lines a replay side ran.
    let replayedCommands: [ClassifierParityReplayedCommand]
    let terminal: ClassifierParityTerminal
    let row: ClassifierParityRowOutcome?

    var project: URL { root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true) }

    var analysisFolder: URL? {
        analysisPath.map { root.appendingPathComponent($0, isDirectory: true) }
    }
}

extension ClassifierCLIGUIParityReplayTests {
    /// Side A or side C, a GUI route. Side A hands the wizard's configs to today's route,
    /// `runClassification(configs:...)` or `runEsViritu(configs:...)`, which run the pipelines in a
    /// detached task. Side C hands them to `launchClassification` or `launchEsViritu`, the
    /// dialog's launch, with every route key set to the CLI route, so `CLIClassifierRunner` runs
    /// the built `lungfish-cli` that `LUNGFISH_CLI_PATH` names. Both register the row on
    /// `OperationCenter.shared`. The test keeps every detail the row and every line the viewer's
    /// overlay showed, waits for the row to finish and reads it.
    func runGUISide(
        _ side: ClassifierParitySide,
        _ parityCase: ClassifierParityCase,
        root: URL,
        esVirituDatabase: URL?
    ) async throws -> ClassifierParitySideRun {
        let project = root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true)
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = OverlayRecordingViewer()
        // A failed run shows its alert as a sheet on the viewer's window, so the viewer gets a
        // window, never ordered front, whose sheet the row outcome reads.
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        let routes = try ClassifierParityCLIRoutes()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
            routes.remove()
        }

        let route = OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        let existing = Set(OperationCenter.shared.items.map(\.id))
        let recorder = RowDetailRecorder(ignoring: existing)
        defer { recorder.stop() }
        switch parityCase.tool {
        case .kraken2:
            let configs = try await parityCase.kraken2Configs(project: project)
            if side == .a {
                delegate.runClassification(configs: configs, viewerController: viewer, routeContext: route)
            } else {
                delegate.launchClassification(configs: configs, viewerController: viewer, routeContext: route, routes: routes.settings)
            }
        case .esViritu:
            let database = try XCTUnwrap(esVirituDatabase)
            let configs = await parityCase.esVirituConfigs(project: project, database: database)
            if side == .a {
                delegate.runEsViritu(configs: configs, viewerController: viewer, routeContext: route)
            } else {
                delegate.launchEsViritu(configs: configs, viewerController: viewer, routeContext: route, routes: routes.settings)
            }
        }
        let started = try XCTUnwrap(
            OperationCenter.shared.items.first { !existing.contains($0.id) },
            "\(parityCase.rawValue): side \(side) started no row"
        )
        let rowID = started.id
        let firstDetail = started.detail
        let finished = await waitUntil(timeout: parityCase.timeout, pollInterval: .milliseconds(100)) {
            OperationCenter.shared.items.first { $0.id == rowID }.map { !$0.state.isActive } ?? true
        }
        XCTAssertTrue(finished, "\(parityCase.rawValue): side \(side)'s row did not finish in \(parityCase.timeout)")
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == rowID })
        if item.state == .failed {
            _ = await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(100)) { window.attachedSheet != nil }
        }
        let row = ClassifierParityRowOutcome(
            title: item.title,
            firstDetail: firstDetail,
            stateLabel: item.displayStateLabel,
            completionDetail: item.detail,
            errorMessage: item.errorMessage,
            alertText: window.attachedSheet.map(Self.texts(in:)),
            logLines: item.logEntries.map { .init(level: $0.level.rawValue, message: $0.message) },
            details: recorder.details[rowID] ?? [firstDetail],
            overlayLines: viewer.overlayLines
        )

        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: analyses,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        // A completed run keeps one folder. A failed one is deleted by today's GUI (D2).
        XCTAssertEqual(
            folders.count,
            item.state == .completed ? 1 : 0,
            "\(parityCase.rawValue): side \(side), \(item.displayStateLabel), left \(folders.map(\.lastPathComponent)) in Analyses"
        )
        return ClassifierParitySideRun(
            side: side,
            root: root,
            analysisPath: folders.first.map { "\(ClassifierParityFixtures.projectName)/Analyses/\($0.lastPathComponent)" },
            recordedCommand: item.cliCommand,
            replayedCommands: [],
            terminal: .row(item.displayStateLabel),
            row: row
        )
    }

    /// Side B or side C'. The command the GUI side's row recorded, rebased onto `root`. Side B
    /// runs it in this process with `RecordedCLICommand`, the way docs/contracts/CLI-EQUIVALENCE.md
    /// replays a command, and side C' runs it with the built `lungfish-cli` (`binaryTerminal`).
    /// The replay may take `timeout`, so a hung replay ends the case and not the tier. A line with `--project` names no folder, so its folder is the one the run made
    /// in the project's `Analyses/`.
    func runReplay(
        _ side: ClassifierParitySide,
        of gui: ClassifierParitySideRun,
        root: URL,
        timeout: Duration
    ) async -> ClassifierParitySideRun {
        guard let command = gui.recordedCommand else {
            return ClassifierParitySideRun(
                side: side, root: root, analysisPath: nil, recordedCommand: nil, replayedCommands: [],
                terminal: .notRun("side \(gui.side)'s row records no command"), row: nil
            )
        }
        let analyses = root.appendingPathComponent("\(ClassifierParityFixtures.projectName)/Analyses", isDirectory: true)
        let before = Set(Self.visibleFolders(in: analyses))
        var replayed: [ClassifierParityReplayedCommand] = []
        let terminal: ClassifierParityTerminal
        do {
            let replay = try RecordedCLICommand.rebased(command, from: gui.root, to: root)
            for line in replay.components(separatedBy: "\n") {
                let arguments = try RecordedCLICommand.arguments(of: line)
                replayed.append(ClassifierParityReplayedCommand(
                    outputFolder: ClassifierParityReplayedCommand.outputFolder(in: arguments),
                    argv: [cliBinary.path] + arguments
                ))
            }
            terminal = side == .cPrime
                ? await Self.binaryTerminal(of: replayed.map { Array($0.argv.dropFirst()) }, cli: cliBinary, timeout: timeout)
                : await Self.replayTerminal(of: replay, timeout: timeout)
        } catch {
            terminal = .error(String(describing: error))
        }
        let made = Self.visibleFolders(in: analyses).filter { !before.contains($0) }
        if replayed.count == 1, replayed[0].outputFolder.isEmpty, made.count == 1 {
            replayed[0] = ClassifierParityReplayedCommand(
                outputFolder: analyses.appendingPathComponent(made[0], isDirectory: true).path,
                argv: replayed[0].argv
            )
        }
        // The folder the replay wrote, `Project.lungfish/Analyses/<name>`, from its first line.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let written = replayed.first.map { URL(fileURLWithPath: $0.outputFolder).resolvingSymlinksInPath().standardizedFileURL.path }
        let analysisPath = written.flatMap { path -> String? in
            guard path.hasPrefix(base) else { return nil }
            return String(path.dropFirst(base.count)).split(separator: "/").prefix(3).joined(separator: "/")
        }
        return ClassifierParitySideRun(
            side: side,
            root: root,
            analysisPath: analysisPath ?? gui.analysisPath,
            recordedCommand: nil,
            replayedCommands: replayed,
            terminal: terminal,
            row: nil
        )
    }

    /// The names of the folders in `folder` that are not hidden, sorted.
    static func visibleFolders(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .map(\.lastPathComponent)
            .sorted()
    }

    /// How `script` ends when it runs in this process, raced against `timeout` in a task group.
    /// The first to finish wins and the other is cancelled. Cancelling the replay stops the tool
    /// it runs through ToolProcess, so a replay that hangs ends as `.error("timed out ...")`.
    nonisolated static func replayTerminal(of script: String, timeout: Duration) async -> ClassifierParityTerminal {
        await withTaskGroup(of: ClassifierParityTerminal.self) { group in
            group.addTask {
                do {
                    try await RecordedCLICommand.runInProcess(script)
                    return .exit(0)
                } catch let exit as ExitCode {
                    return .exit(exit.rawValue)
                } catch {
                    return .error(String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .error("timed out after \(timeout)")
            }
            let first = await group.next() ?? .error("the replay returned nothing")
            group.cancelAll()
            return first
        }
    }

    /// How `lines` end when the built `lungfish-cli` runs each of them, one after another, through
    /// `CLISubprocessTransport`, the launch the GUI route uses, each raced against `timeout`.
    /// Side C' replays this way. A run in this process records the test runner's argv, its
    /// version and the options `kraken2 classify` reads from that argv, where the binary side C
    /// ran records its own.
    nonisolated static func binaryTerminal(of lines: [[String]], cli: URL, timeout: Duration) async -> ClassifierParityTerminal {
        for arguments in lines {
            let transport = CLISubprocessTransport(cliURLOverride: cli)
            let terminal = await withTaskGroup(of: ClassifierParityTerminal.self) { group in
                group.addTask {
                    do {
                        _ = try await transport.run(arguments: arguments, isCancelled: { false }, onEvent: { _ in })
                        return .exit(0)
                    } catch CLISubprocessTransport.RunError.nonZeroExit(let status, _) {
                        return .exit(status)
                    } catch {
                        return .error(String(describing: error))
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return .error("timed out after \(timeout)")
                }
                let first = await group.next() ?? .error("the replay returned nothing")
                if case .error(let message) = first, message.hasPrefix("timed out") {
                    transport.cancel()
                }
                group.cancelAll()
                return first
            }
            guard terminal == .exit(0) else { return terminal }
        }
        return .exit(0)
    }

    /// The text fields of a sheet, top to bottom, one per line.
    static func texts(in window: NSWindow) -> String {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return texts.joined(separator: "\n")
    }
}
