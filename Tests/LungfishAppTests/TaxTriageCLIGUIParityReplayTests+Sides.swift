// TaxTriageCLIGUIParityReplayTests+Sides.swift - The TaxTriage parity cases, their engine and the runs of their sides
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Side A drives the GUI route the hidden key's `legacy` value selects, `launchTaxTriage(route: .legacy)`
// and so `AppDelegate.runTaxTriage`, with the config the TaxTriage wizard builds for the case's bundles
// and the GUI's runner seam (`AppDelegate.TaxTriageLaunchSeam.makeRunner`) bound to the case's engine.
// Side C drives the same launch with the `cli` value (Phase 2.11 U30 M3). Side B rebases the
// command side A's row recorded onto a fresh root and runs it in this process with the CLI's
// pipeline seam (`TaxTriageCommand.RunSubcommand.makePipeline`) bound to the same engine
// (2.7 T2). Each run keeps the launches the stand-in recorded while it ran.

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

/// The cases of section 2.2 of the 2.9 QA inventory that sides A and B run.
enum TaxTriageParityCase: String, CaseIterable, Sendable {
    /// One sample, the classifier golden's virtual subset bundle of 55 reads.
    case x1 = "X1"
    /// The SARS-CoV-2 pair as one sample of two mates.
    case x2 = "X2"
    /// Two samples in one launch request, copies of the pair and the negative control in one folder.
    case x3 = "X3"
    /// X3's two samples, of which the negative control fails.
    case x4 = "X4"
    /// The pair as one sample, whose run ignores one errored task.
    case x5 = "X5"
    /// The pair as one sample, cancelled once the engine has started.
    case x6 = "X6"
    /// The pair as one sample whose organism report lists nothing, rebuilt with `--force` after
    /// the cleanup.
    case x7 = "X7"
    /// A plain `--output` of two samples, the merge bundle and the negative control, on side B
    /// only.
    case x8 = "X8"

    /// The folder of the two bundles a request of two samples names, relative to the project. It
    /// holds copies of the case's two bundles and nothing else, so a folder `--input` names
    /// exactly the two samples.
    static let twoSampleFolder = "Imports/two-samples"

    /// The bundles copied into `twoSampleFolder` for a request of two samples, as the project
    /// holds them.
    var folderSources: [String] {
        switch self {
        case .x3, .x4: return [ClassifierParityFixtures.negativeControlBundlePath, ClassifierParityFixtures.pairBundlePath]
        case .x8: return [ClassifierParityFixtures.mergeBundlePath, ClassifierParityFixtures.negativeControlBundlePath]
        case .x1, .x2, .x5, .x6, .x7: return []
        }
    }

    /// The bundles the request names, relative to the project.
    var bundlePaths: [String] {
        switch self {
        case .x1: return [ClassifierParityFixtures.subsetBundlePath]
        case .x2, .x5, .x6, .x7: return [ClassifierParityFixtures.pairBundlePath]
        case .x3, .x4, .x8: return folderSources.map { "\(Self.twoSampleFolder)/\(($0 as NSString).lastPathComponent)" }
        }
    }

    var isBatch: Bool { bundlePaths.count > 1 }

    /// The folder side B's pooled command names for a request whose row records no command.
    var pooledInputFolder: String? { isBatch ? Self.twoSampleFolder : nil }

    /// Whether a side materializes a virtual bundle, which runs seqkit.
    var materializesVirtualBundle: Bool { self == .x1 }

    /// The wizard's run token, fixed. `runTaxTriage` replaces the folder it names.
    static let runToken = "0000PAR1"

    /// The project every side of the case starts from, built in `root`: the classifier parity
    /// project, and for two samples the folder that holds their bundles.
    func makeProject(in root: URL) throws -> URL {
        let project = try ClassifierParityFixtures.makeProject(in: root)
        guard isBatch else { return project }
        let folder = project.appendingPathComponent(Self.twoSampleFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for source in folderSources {
            let bundle = project.appendingPathComponent(source, isDirectory: true)
            try FileManager.default.copyItem(at: bundle, to: folder.appendingPathComponent(bundle.lastPathComponent, isDirectory: true))
        }
        return project
    }

    /// The config `TaxTriageWizardSheet.performRun` builds when the operations dialog hands it
    /// the case's bundles (`resolveFASTQOperationInputURLs` gives bundle URLs). One sample per
    /// bundle, named and ordered as `populateFromInitialFiles` names and orders them, with the
    /// wizard's defaults: Illumina, the test sample role and the host taxid it brings, 10 top
    /// hits, confidence 0.2, assembly skipped, Krona on, 16 GB and no extra arguments. The CPU
    /// count, the profile and the database come from the engine, since a stand-in cannot run
    /// the wizard's docker profile. `runTaxTriage` replaces the output folder with one in
    /// `Analyses/`.
    @MainActor
    func wizardConfig(project: URL, engine: TaxTriageParityEngine) -> TaxTriageConfig {
        let bundles = bundlePaths.map { project.appendingPathComponent($0, isDirectory: true) }
        let samples = bundles.map { bundle -> TaxTriageSample in
            let sampleID = Self.wizardSampleID(for: bundle)
            var metadata = FASTQSampleMetadata(sampleName: sampleID)
            metadata.sampleRole = .testSample
            return TaxTriageSample(sampleId: sampleID, fastq1: bundle, platform: .illumina, metadata: metadata)
        }
        .sorted { $0.sampleId < $1.sampleId }
        let removeTaxidsText = TaxTriageWizardSheet.removeTaxidsText(
            current: "",
            userEdited: false,
            sampleRoles: samples.map { $0.metadata?.sampleRole ?? .testSample }
        )
        let parents = Set(bundles.map { $0.deletingLastPathComponent().standardizedFileURL })
        return TaxTriageConfig(
            samples: samples,
            platform: .illumina,
            outputDirectory: bundles[0].deletingLastPathComponent().appendingPathComponent("taxtriage-\(Self.runToken)"),
            kraken2DatabasePath: engine.databasePath,
            topHitsCount: 10,
            k2Confidence: 0.2,
            skipAssembly: true,
            skipKrona: false,
            maxMemory: "16.GB",
            maxCpus: engine.maxCpus,
            profile: engine.profile,
            sourceBundleURLs: parents.count > 1 ? parents.sorted { $0.path < $1.path } : nil,
            extraArguments: [],
            removeTaxids: TaxTriageWizardSheet.effectiveRemoveTaxids(text: removeTaxidsText, extraArguments: [])
        )
    }

    /// The sample name `populateFromInitialFiles` gives an input: its name without the
    /// extension, a `.gz` and one mate suffix.
    static func wizardSampleID(for url: URL) -> String {
        var base = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "gz" {
            base = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        for suffix in ["_R1", "_R2", "_1", "_2", "_R1_001", "_R2_001"] where base.hasSuffix(suffix) {
            return String(base.dropLast(suffix.count))
        }
        return base
    }
}

/// What one sample of a case holds, from the fixtures alone.
struct TaxTriageParitySampleFacts: Sendable {
    let sampleID: String
    /// The records the engine must count in each samplesheet column, `fastq_1` first.
    let records: [Int]

    var isPair: Bool { records.count == 2 }

    static func forBundle(_ path: String) -> TaxTriageParitySampleFacts {
        switch (path as NSString).lastPathComponent {
        case "sarscov2-pair.lungfishfastq":
            // test_1 and test_2, 100 records each, run as the two mates of one sample.
            return .init(sampleID: "sarscov2-pair", records: [ClassifierParityFixtures.rootReads, ClassifierParityFixtures.rootReads])
        case "negative-control.lungfishfastq":
            return .init(sampleID: "negative-control", records: [40])
        case "merge.lungfishfastq":
            // 77 merged reads and 23 unmerged pairs.
            return .init(sampleID: "merge", records: [123])
        default:
            // The virtual subset holds 55 reads, its preview 10 and its root 100.
            return .init(sampleID: "len-150-any-00000000", records: [ClassifierParityFixtures.subsetReads])
        }
    }
}

/// The sides of a TaxTriage parity case (2.7 T2).
enum TaxTriageParitySide: String, CaseIterable, Sendable, CustomStringConvertible {
    /// Today's GUI route through `AppDelegate`, run on `OperationCenter.shared`.
    case a = "A"
    /// The command side A's row recorded, rebased onto a fresh root and run in this process.
    case b = "B"
    /// The route the hidden key's `cli` value selects, `launchTaxTriage(route: .cli)`, which runs
    /// `taxtriage run --project` through the built `lungfish-cli` on the case's engine with an
    /// Operations panel row (2.8 T1, T4 and T17, Phase 2.11 U30 M3). X8, which no GUI route makes,
    /// runs its plain `--output` through the same binary (lane Q1b, TaxTriageCLIGUIParityReplayTests+RouteC.swift).
    case c = "C"
    /// The argv side C's root record names, rebased onto a fresh root and run by the built
    /// `lungfish-cli` that side C ran.
    case cPrime = "C'"

    var description: String { rawValue }

    /// The folder of the side's root, a name a recorded command needs no quote for.
    var folderName: String { self == .cPrime ? "C-prime" : rawValue }

    /// Whether the side runs a GUI route and so has an Operations panel row, on every case but X8.
    var hasRow: Bool { self == .a || self == .c }
}

/// How a side's run ended.
enum TaxTriageParityTerminal: Equatable, Sendable, CustomStringConvertible {
    /// The final state label of an Operations panel row.
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
struct TaxTriageParityReplayedCommand: Sendable {
    /// The folder the line writes, the value of `--output`.
    let outputFolder: String
    /// The built `lungfish-cli` path followed by the line's arguments.
    let argv: [String]

    static func outputFolder(in arguments: [String]) -> String {
        for option in ["--output", "-o"] {
            if let index = arguments.firstIndex(of: option), index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return ""
    }
}

/// Side B's command for a request of several samples is no longer a plain `--output` pooled run.
struct TaxTriageParityPooledCommandError: Error, CustomStringConvertible {
    let words: [String]

    var description: String {
        "The one-sample spelling no longer gives a plain --output pooled run (2.8 T17). Side B of several "
            + "samples stays pooled (2.8 T2, 2.9 T5), so re-spell pooledCommand. Words \(words)"
    }
}

/// The Operations panel row of a GUI run, what a user reads.
struct TaxTriageParityRow: Equatable, Sendable {
    let title: String
    let firstDetail: String
    let stateLabel: String
    let completionDetail: String
    let errorMessage: String?
    /// The text of the alert sheet the run left on the viewer's window, nil for none.
    let alertText: String?
    /// Each log line as `[level] message`.
    let logLines: [String]
    /// Every detail the row showed while it ran, in order, the first detail first.
    let details: [String]
    /// Every line the viewer's progress overlay showed, in order.
    let overlayLines: [String]
}

/// The engine every side of a case runs on (QA ruling O5). Its root, Nextflow profile, Kraken2
/// database, CPU count and the wait for one side's run are parameters, and both launch seams
/// build `makePipeline`, so a live class runs the same sides on a managed root with the docker
/// profile. `standIn` is the stand-in whose launch records the fixed facts read, nil on a live
/// root.
struct TaxTriageParityEngine: Sendable {
    let root: URL
    let profile: String
    let databasePath: URL
    let maxCpus: Int
    /// How long one side's run may take. Each wait ends as soon as the run does.
    let processWait: Duration
    let makePipeline: @Sendable () -> TaxTriagePipeline
    let standIn: TaxTriageStandInEngine?
    /// What the built `lungfish-cli` of sides C and C' adds to its environment to launch this
    /// engine, nothing on a managed root.
    var cliEnvironment: [String: String] = [:]

    /// The stand-in engine of 2.8 TF-G with the `local` profile, one CPU (QA 6) and a 30-second
    /// wait. The built `lungfish-cli` finds it as the managed Nextflow of its conda root, with a
    /// storage root and a home of its own inside the engine, so no side writes to the real ones.
    static func standIn(_ engine: TaxTriageStandInEngine, databasePath: URL) -> TaxTriageParityEngine {
        TaxTriageParityEngine(
            root: engine.root,
            profile: TaxTriageStandInEngine.profile,
            databasePath: databasePath,
            maxCpus: 1,
            processWait: .seconds(30),
            makePipeline: { engine.makePipeline() },
            standIn: engine,
            cliEnvironment: [
                "LUNGFISH_CONDA_ROOT": engine.condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": engine.root.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": engine.home.path,
            ]
        )
    }

    /// The serial batch runner `runTaxTriage` reads from `AppDelegate.TaxTriageLaunchSeam`.
    var makeRunner: @Sendable () -> TaxTriageSerialBatchRunner {
        let makePipeline = makePipeline
        return {
            TaxTriageSerialBatchRunner(runPipeline: { config, progress in
                try await makePipeline().run(config: config, progress: progress)
            })
        }
    }

    /// Every launch the stand-in recorded, in launch order, none on a live root.
    func launches() throws -> [TaxTriageStandInEngine.Launch] {
        try standIn?.launches() ?? []
    }
}

/// What one side's run left for the comparisons.
struct TaxTriageParitySideRun {
    let side: TaxTriageParitySide
    let root: URL
    /// The analysis folder relative to `root`, nil when the run made none.
    let analysisPath: String?
    /// The command the side's row recorded, for a GUI side.
    let recordedCommand: String?
    /// The lines a replay side ran.
    let replayedCommands: [TaxTriageParityReplayedCommand]
    let terminal: TaxTriageParityTerminal
    let row: TaxTriageParityRow?
    /// The stand-in's launches while the side ran, in launch order.
    let launches: [TaxTriageStandInEngine.Launch]
    /// X7's `--force` rebuild after the run, nil for the other cases.
    var rebuild: TaxTriageParityRebuild?

    /// A side the case does not run, for `reason`.
    static func notRun(_ side: TaxTriageParitySide, root: URL, reason: String) -> TaxTriageParitySideRun {
        TaxTriageParitySideRun(
            side: side, root: root, analysisPath: nil, recordedCommand: nil, replayedCommands: [],
            terminal: .notRun(reason), row: nil, launches: []
        )
    }

    var project: URL { root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true) }

    var analysisFolder: URL? {
        analysisPath.map { root.appendingPathComponent($0, isDirectory: true) }
    }
}

extension TaxTriageParityHarness {
    /// A GUI side. Hands the wizard's config to `launchTaxTriage`, the dialog's launch, on the route
    /// of the hidden key's value the side stands for (Phase 2.11 U30 M3, ARCH 7, both routes in one
    /// parity class). Side A takes `legacy`, which runs `runTaxTriage` with the GUI's runner seam
    /// bound to the engine. Side C takes `cli`, which runs `taxtriage run --project` through the
    /// built `lungfish-cli` on the classifier CLI route's row (`cliRouteExecutable`). The side keeps
    /// every detail of the row and every line of the viewer's overlay, waits for the row to finish
    /// and reads it.
    func runGUISide(
        _ parityCase: TaxTriageParityCase,
        side: TaxTriageParitySide = .a,
        root: URL,
        engine: TaxTriageParityEngine
    ) async throws -> TaxTriageParitySideRun {
        let route: TaxTriageLaunchRoute = side == .a ? .legacy : .cli
        let project = root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true)
        let config = parityCase.wizardConfig(project: project, engine: engine)
        let delegate = testCase.makeAppDelegateWithTemporaryState()
        let viewer = OverlayRecordingViewer()
        // A failed run shows its alert as a sheet on the viewer's window, so the viewer gets a
        // window, never ordered front, whose sheet the row outcome reads.
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }

        let launchesBefore = try engine.launches().count
        let existing = Set(OperationCenter.shared.items.map(\.id))
        let recorder = RowDetailRecorder(ignoring: existing)
        defer { recorder.stop() }
        let routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        switch route {
        case .legacy:
            AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue(engine.makeRunner) {
                delegate.launchTaxTriage(config: config, viewerController: viewer, routeContext: routeContext, route: .legacy)
            }
        case .cli:
            let cli = try cliRouteExecutable(engine: engine)
            delegate.launchTaxTriage(config: config, viewerController: viewer, routeContext: routeContext, route: .cli, cliURLOverride: cli)
        }
        let started = try XCTUnwrap(
            OperationCenter.shared.items.first { !existing.contains($0.id) },
            "\(parityCase.rawValue): side \(side) started no row"
        )
        let rowID = started.id
        let firstDetail = started.detail
        if parityCase.cancelsOnceTheEngineStarts {
            // The Operations panel's Cancel, once the engine runs (QA inventory 2.2, X6).
            let launch = await engine.standIn?.waitForLaunch(launchesBefore, timeout: engine.processWait)
            XCTAssertNotNil(launch, "\(parityCase.rawValue): side \(side)'s engine never started")
            OperationCenter.shared.cancel(id: rowID)
        }
        let finished = await waitUntil(timeout: engine.processWait, pollInterval: .milliseconds(100)) {
            OperationCenter.shared.items.first { $0.id == rowID }.map { !$0.state.isActive } ?? true
        }
        XCTAssertTrue(finished, "\(parityCase.rawValue): side \(side)'s row did not finish in \(engine.processWait)")
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == rowID })
        if item.state == .failed {
            _ = await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(100)) { window.attachedSheet != nil }
        }
        let row = TaxTriageParityRow(
            title: item.title,
            firstDetail: firstDetail,
            stateLabel: item.displayStateLabel,
            completionDetail: item.detail,
            errorMessage: item.errorMessage,
            alertText: window.attachedSheet.map(Self.texts(in:)),
            logLines: item.logEntries.map { "[\($0.level.rawValue)] \($0.message)" },
            details: recorder.details[rowID] ?? [firstDetail],
            overlayLines: viewer.overlayLines
        )

        let folders = Self.visibleFolders(in: project.appendingPathComponent("Analyses", isDirectory: true))
        // A completed run keeps one folder, and so does a cancelled one, with its cancelled record
        // (TaxTriagePipelineCancelReplayTests, 2.8 S1).
        XCTAssertEqual(
            folders.count,
            item.state == .completed || item.state == .cancelled ? 1 : 0,
            "\(parityCase.rawValue): side \(side), \(item.displayStateLabel), left \(folders) in Analyses"
        )
        return TaxTriageParitySideRun(
            side: side,
            root: root,
            analysisPath: folders.first.map { "\(ClassifierParityFixtures.projectName)/Analyses/\($0)" },
            recordedCommand: item.cliCommand,
            replayedCommands: [],
            terminal: .row(item.displayStateLabel),
            row: row,
            launches: Array(try engine.launches().dropFirst(launchesBefore))
        )
    }

    /// Side B. The command side A's row recorded, rebased onto `root`, or for a request whose row
    /// records none the pooled command of the same request (`pooledCommand`), run in this process
    /// with the CLI's pipeline seam bound to the engine, the way docs/contracts/CLI-EQUIVALENCE.md
    /// replays a command. Since 2.9 S11 `taxtriage run` runs its pipeline in a task that only a
    /// SIGTERM cancels, so the engine's wait no longer cuts a hung replay. A stand-in launch that
    /// waits gives up after the stand-in's maximumWait, which bounds the case.
    func runReplay(
        of gui: TaxTriageParitySideRun,
        _ parityCase: TaxTriageParityCase,
        root: URL,
        engine: TaxTriageParityEngine
    ) async -> TaxTriageParitySideRun {
        let side = TaxTriageParitySide.b
        let launchesBefore = (try? engine.launches().count) ?? 0
        var replayed: [TaxTriageParityReplayedCommand] = []
        let terminal: TaxTriageParityTerminal
        do {
            let script: String?
            if let command = gui.recordedCommand {
                script = try RecordedCLICommand.rebased(command, from: gui.root, to: root)
            } else if let folder = parityCase.pooledInputFolder {
                script = try pooledCommand(parityCase, folder: folder, gui: gui, root: root, engine: engine)
            } else {
                script = nil
            }
            if let script {
                for line in script.components(separatedBy: "\n") {
                    let arguments = try RecordedCLICommand.arguments(of: line)
                    replayed.append(TaxTriageParityReplayedCommand(
                        outputFolder: TaxTriageParityReplayedCommand.outputFolder(in: arguments),
                        argv: [cliBinary.path] + arguments
                    ))
                }
                if parityCase.cancelsOnceTheEngineStarts {
                    terminal = await Self.replayTerminalCancelledBySIGTERM(of: script, engine: engine, launchesBefore: launchesBefore)
                } else {
                    terminal = await Self.replayTerminal(of: script, engine: engine)
                }
            } else {
                terminal = .notRun("side \(gui.side)'s row records no command")
            }
        } catch {
            terminal = .error(String(describing: error))
        }
        // The folder the replay wrote, `Project.lungfish/Analyses/<name>`, from its first line.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let written = replayed.first.map { URL(fileURLWithPath: $0.outputFolder).resolvingSymlinksInPath().standardizedFileURL.path }
        let analysisPath = written.flatMap { path -> String? in
            guard path.hasPrefix(base) else { return nil }
            return String(path.dropFirst(base.count)).split(separator: "/").prefix(3).joined(separator: "/")
        }
        return TaxTriageParitySideRun(
            side: side,
            root: root,
            analysisPath: analysisPath,
            recordedCommand: nil,
            replayedCommands: replayed,
            terminal: terminal,
            row: nil,
            launches: Array(((try? engine.launches()) ?? []).dropFirst(launchesBefore))
        )
    }

    /// Today's one command for a request of several samples, which side A's row does not record
    /// (cli-parity-gap taxtriage-multi-sample). It is the command the row records for one
    /// sample, with the samples' folder as its one `--input` and without `--sample`, so
    /// `taxtriage run` makes one sample of each bundle and runs them all in one Nextflow (2.8 T2,
    /// Q15 R1). It writes the folder side A's run made, rebased onto `root`.
    func pooledCommand(
        _ parityCase: TaxTriageParityCase,
        folder: String,
        gui: TaxTriageParitySideRun,
        root: URL,
        engine: TaxTriageParityEngine
    ) throws -> String {
        let project = root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true)
        var config = parityCase.wizardConfig(project: project, engine: engine)
        config.samples = [TaxTriageSample(
            sampleId: "pooled",
            fastq1: project.appendingPathComponent(folder, isDirectory: true),
            platform: config.platform
        )]
        config.outputDirectory = root.appendingPathComponent(
            gui.analysisPath ?? "\(ClassifierParityFixtures.projectName)/Analyses/taxtriage-pooled",
            isDirectory: true
        )
        var words = try RecordedCLICommand.arguments(of: AppDelegate.taxTriageCLICommand(for: config))
        if let index = words.firstIndex(of: "--sample"), index + 1 < words.count {
            words.removeSubrange(index...(index + 1))
        }
        // 2.8 T17 changes the spelling of a one-sample row with A2, while 2.8 T2 and 2.9 T5 keep a
        // plain --output pooled. Side B of several samples stays that pooled run, so a spelling
        // that loses --output or gains --project or --batch means re-spelling this command.
        guard Self.resolved(TaxTriageParityReplayedCommand.outputFolder(in: words)) == Self.resolved(config.outputDirectory.path),
              !words.contains("--project"), !words.contains("--batch"), !words.contains("--sample") else {
            throw TaxTriageParityPooledCommandError(words: words)
        }
        return OperationCenter.buildCLICommand(subcommand: "", args: words)
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

    /// The names of the folders in `folder` that are not hidden, sorted.
    static func visibleFolders(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .map(\.lastPathComponent)
            .sorted()
    }

    /// How `script` ends when it runs in this process with the CLI's pipeline seam bound to the
    /// engine, raced against the engine's wait in a task group. The first to finish gives the end,
    /// but the group still waits for the replay, because its cancel does not reach the task
    /// `taxtriage run` starts (2.9 S11). Child tasks inherit the seam's task-local value.
    nonisolated static func replayTerminal(of script: String, engine: TaxTriageParityEngine) async -> TaxTriageParityTerminal {
        let timeout = engine.processWait
        return await TaxTriageCommand.RunSubcommand.$makePipeline.withValue(engine.makePipeline) {
            await withTaskGroup(of: TaxTriageParityTerminal.self) { group in
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
    }
}
