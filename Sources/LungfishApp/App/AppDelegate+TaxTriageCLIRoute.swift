// AppDelegate+TaxTriageCLIRoute.swift - The TaxTriage launch through lungfish-cli taxtriage run, behind its key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the TaxTriage CLI route runs for one launch of the FASTQ operations dialog (Phase 2.11 lane
/// U30, panel decision K1). The hidden key `TaxTriageLaunchRoute` chooses it (``TaxTriageLaunchRoute``).
///
/// The argv is `taxtriage run` with the words the legacy row records for one sample
/// (`AppDelegate.taxTriageCLICommand(for:)`) and `--project` in place of `--output`, the words the
/// parity class's side C runs (2.8 T17). The command then makes `Analyses/taxtriage-batch-<timestamp>/`
/// in the project, as the legacy route does for one sample too (UX F7). Several samples take one
/// `--input` each, in the dialog's order, and `--batch`, so each sample runs alone in its own folder as
/// the legacy serial batch does. A sample of one file takes that file. A pair takes the FASTQ bundle
/// that holds both files, which the command plans as a pair, since `--input2` names the mate of one
/// `--input` only. Each sample the dialog marks as a negative control takes `--negative-control`, so the
/// argv carries every effective parameter (BIO, 2.10 `inv/BIO.md:141`). The row records this argv, the
/// one the transport runs.
struct TaxTriageCLIRouteLaunch: Sendable, Equatable {
    /// The argv after `lungfish-cli`.
    let arguments: [String]
    /// Today's row title and first detail (UX F13).
    let title: String
    let firstDetail: String
    /// The names the command gives the samples, in the dialog's order. One sample keeps the dialog's
    /// name through `--sample`. Several are named after their input, as `taxtriage run` names each
    /// sample of several `--input` (`TaxTriageAnalysisRunTool.sampleID(for:explicitSampleID:totalSampleCount:)`).
    let sampleIDs: [String]

    var isBatch: Bool {
        sampleIDs.count > 1
    }

    /// The command the row records, `lungfish-cli` followed by ``arguments``.
    var cliCommand: String {
        OperationCenter.buildCLICommand(
            subcommand: arguments.prefix(2).joined(separator: " "),
            args: Array(arguments.dropFirst(2))
        )
    }

    /// Today's title of the alert after a failed run, for one sample and for several (UX F5).
    static let failureAlertTitle = "TaxTriage Failed"
    /// The name `canWriteProjectOutputs` shows when the project is read-only, today's.
    static let workflowName = "TaxTriage"

    /// The launch of `config` into `projectURL`, or nil for a config with no sample.
    ///
    /// - Throws: ``TaxTriageCLIRouteRefusal`` when one `taxtriage run` argv cannot carry the samples.
    static func taxTriage(config: TaxTriageConfig, projectURL: URL) throws(TaxTriageCLIRouteRefusal) -> TaxTriageCLIRouteLaunch? {
        let samples = config.samples
        guard let first = samples.first else { return nil }
        var arguments = ["taxtriage", "run"]
        let sampleIDs: [String]
        if samples.count == 1 {
            arguments += ["--input", first.fastq1.path]
            if let fastq2 = first.fastq2 {
                arguments += ["--input2", fastq2.path]
            }
            arguments += ["--sample", first.sampleId]
            sampleIDs = [first.sampleId]
        } else {
            var inputs: [URL] = []
            for sample in samples {
                inputs.append(try batchInput(of: sample))
            }
            arguments += inputs.flatMap { ["--input", $0.path] }
            sampleIDs = inputs.map(commandSampleName(of:))
        }
        arguments += ["--project", projectURL.path]
        if samples.count > 1 {
            arguments.append("--batch")
        }
        for (sample, name) in zip(samples, sampleIDs) where sample.isNegativeControl {
            arguments += ["--negative-control", name]
        }
        arguments += settingsArguments(of: config, platform: samples.count == 1 ? first.platform : config.platform)
        arguments += ["--format", "json"]
        let sampleCount = samples.count
        return TaxTriageCLIRouteLaunch(
            arguments: arguments,
            title: "TaxTriage (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            firstDetail: "Starting TaxTriage pipeline\u{2026}",
            sampleIDs: sampleIDs
        )
    }

    /// The `--input` of one sample of several. A pair takes the FASTQ bundle that holds both files.
    private static func batchInput(of sample: TaxTriageSample) throws(TaxTriageCLIRouteRefusal) -> URL {
        guard let fastq2 = sample.fastq2 else { return sample.fastq1 }
        guard let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: sample.fastq1),
              SequenceInputResolver.enclosingFASTQBundleURL(for: fastq2)?.standardizedFileURL == bundle.standardizedFileURL else {
            throw .pairOutsideABundle(sampleID: sample.sampleId)
        }
        return bundle
    }

    /// The name `taxtriage run` gives the sample of one of several `--input`, the input's name without
    /// its last two extensions, so `S1.fastq.gz` and `S1.lungfishfastq` both give `S1`.
    static func commandSampleName(of input: URL) -> String {
        input.deletingPathExtension().deletingPathExtension().lastPathComponent
    }

    /// The settings words, in the order and spelling of the legacy row's command.
    private static func settingsArguments(of config: TaxTriageConfig, platform: TaxTriageConfig.Platform) -> [String] {
        var arguments: [String] = []
        if let databasePath = config.kraken2DatabasePath {
            arguments += ["--db", databasePath.path]
        }
        arguments += ["--platform", platform.rawValue.lowercased()]
        arguments += ["--confidence", String(config.k2Confidence)]
        arguments += ["--top-hits", String(config.topHitsCount)]
        arguments += ["--rank", config.rank]
        if !config.skipAssembly {
            arguments.append("--no-skip-assembly")
        }
        if config.skipKrona {
            arguments.append("--skip-krona")
        }
        if let removeTaxids = config.effectiveRemoveTaxids {
            arguments += ["--remove-taxids", removeTaxids]
        }
        arguments += ["--max-memory", config.maxMemory]
        arguments += ["--max-cpus", String(config.maxCpus)]
        arguments += ["--nf-profile", config.profile]
        // The row names the revision the run takes, the pinned commit when the config names none (N4).
        if let revision = config.revision ?? (try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())?.revision {
            arguments += ["--revision", revision]
        }
        if !config.extraArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
        }
        return arguments
    }
}

/// Why the TaxTriage CLI route refuses a launch before it starts anything, in words (owner direction
/// of 2026-10-15, UX U-211-1).
enum TaxTriageCLIRouteRefusal: Error, Equatable {
    /// A pair of reads of a launch of several samples whose files lie in no one FASTQ bundle.
    /// `taxtriage run` takes the mate of one `--input` only, so the argv could not keep the pair.
    case pairOutsideABundle(sampleID: String)

    var title: String {
        "TaxTriage Cannot Run These Samples"
    }

    var message: String {
        switch self {
        case .pairOutsideABundle(let sampleID):
            return "Sample \(sampleID) is a pair of reads outside a FASTQ bundle. A TaxTriage run of several samples reads each pair from its bundle. Import the reads into the project, or run this sample alone."
        }
    }
}

extension AppDelegate {
    // MARK: - Launch

    /// Runs the TaxTriage `config` through `lungfish-cli taxtriage run --project` with today's row
    /// title and first detail. A launch with no project open is refused with the `No Project Open`
    /// sheet and starts nothing (decision L1), and a launch one argv cannot carry is refused in words.
    func runTaxTriageThroughCLI(
        config: TaxTriageConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        cliURLOverride: URL? = nil
    ) {
        guard !config.samples.isEmpty else { return }
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL else {
            refuseClassifierLaunchWithoutProject(
                tool: FASTQOperationToolID.taxTriage.title,
                viewerController: viewerController,
                routeContext: routeContext
            )
            return
        }
        let launch: TaxTriageCLIRouteLaunch
        do {
            guard let made = try TaxTriageCLIRouteLaunch.taxTriage(config: config, projectURL: projectURL) else { return }
            launch = made
        } catch {
            // The refusal presenter of a classifier launch, which sits as a sheet on the window and
            // is app-modal with none (decision A4), and which a test records.
            NoProjectPresenterSeam.presenter.present(
                title: error.title,
                message: error.message,
                on: viewerController.view.window ?? targetMainWindowController(routeContext: routeContext)?.window
            )
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: TaxTriageCLIRouteLaunch.workflowName
        ) else { return }
        let transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
        Self.beginTaxTriageCLIRouteOperation(launch, routeContext: routeContext) { operationID in
            Task { @MainActor [weak self] in
                do {
                    let result = try await Self.runTaxTriageCommand(
                        launch,
                        transport: transport,
                        operationID: operationID,
                        viewerController: viewerController
                    )
                    Self.finishTaxTriageThroughCLI(
                        result,
                        operationID: operationID,
                        viewerController: viewerController,
                        routeContext: routeContext,
                        appDelegate: self
                    )
                } catch is CancellationError {
                    viewerController.hideProgress()
                    OperationCenter.shared.acknowledgeCancellation(id: operationID)
                } catch {
                    Self.failTaxTriageThroughCLI(error, operationID: operationID, viewerController: viewerController)
                }
            }
            OperationCenter.shared.setCancelCallback(for: operationID) {
                // The overlay reads the row's `Cancelling...` through the grace of the cancel (UX 4).
                Self.showTaxTriageCancelling(for: operationID, on: viewerController)
                transport.cancel()
            }
        }
    }

    /// Registers the TaxTriage CLI route's row with today's title and first detail and the argv the
    /// transport runs, and calls `start` only when the row started. Like today's row it locks no
    /// bundle, so a real `OperationCenter` never refuses it.
    @discardableResult
    static func beginTaxTriageCLIRouteOperation(
        _ launch: TaxTriageCLIRouteLaunch,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        start: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: launch.title,
            detail: launch.firstDetail,
            operationType: .classification,
            cliCommand: launch.cliCommand,
            routeContext: routeContext
        )
        if case .started(let operationID) = result {
            start(operationID)
        }
        return result
    }

    /// Runs the command for the row `operationID`. `OperationCenterCLIBridge` moves the bar with the
    /// executor's fraction, which is on the run's scale already, so no fraction goes through
    /// `showTaxTriageProgress` (2.10 FXU). The early `output` line names the folder the row tracks
    /// for Results and Reveal Output Files, which keeps it hidden while the command runs.
    @concurrent
    private static func runTaxTriageCommand(
        _ launch: TaxTriageCLIRouteLaunch,
        transport: CLISubprocessTransport,
        operationID: UUID,
        viewerController: ViewerViewController
    ) async throws -> CLISubprocessTransport.Result {
        let bridge = OperationCenterCLIBridge.onEvent(operationID: operationID) { line in
            viewerController.showProgress(line)
        }
        return try await transport.run(
            arguments: launch.arguments,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
            onEvent: { event in
                bridge(event)
                if case let .output(path, role) = event, role == CLIEventArtifact.Role.analysisDirectory, !path.isEmpty {
                    let folder = URL(fileURLWithPath: path, isDirectory: true)
                    Task { @MainActor in OperationCenter.shared.trackAnalysisOutput(folder, for: operationID) }
                }
            }
        )
    }

    // MARK: - End of run

    /// Completes the row with the command's message and ends the run as the legacy route does
    /// (UX F4). Nothing opens and the sidebar reloads. The command wrote the result, its records and
    /// the source bundle entries, so nothing is written here, no sidecar and no run history (R1).
    private static func finishTaxTriageThroughCLI(
        _ result: CLISubprocessTransport.Result,
        operationID: UUID,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?,
        appDelegate: AppDelegate?
    ) {
        viewerController.hideProgress()
        guard OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else {
            OperationCenter.shared.acknowledgeCancellation(id: operationID)
            return
        }
        guard OperationCenter.shared.complete(id: operationID, detail: result.message ?? "") else { return }
        appDelegate?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
            .sidebarController.requestReloadFromFilesystem()
    }

    /// Fails the row with the command's message and shows today's `TaxTriage Failed` alert with the
    /// message as its text (UX F5). The command keeps the failed folder hidden with its records, so
    /// nothing is removed here.
    private static func failTaxTriageThroughCLI(
        _ error: Error,
        operationID: UUID,
        viewerController: ViewerViewController
    ) {
        viewerController.hideProgress()
        let message: String
        if case let CLISubprocessTransport.RunError.failedEvent(failedMessage, _) = error {
            message = failedMessage
        } else {
            message = error.localizedDescription
        }
        guard OperationCenter.shared.fail(id: operationID, detail: message) else { return }
        let alert = NSAlert()
        alert.messageText = TaxTriageCLIRouteLaunch.failureAlertTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = viewerController.view.window {
            alert.beginSheetModal(for: window)
        }
    }
}
