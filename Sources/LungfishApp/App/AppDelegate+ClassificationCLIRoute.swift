// AppDelegate+ClassificationCLIRoute.swift - Kraken2 and EsViritu launches run through lungfish-cli, looking as today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the CLI route runs for one launch of the FASTQ operations dialog (Phase 2.7 lane A10,
/// panel decisions E1, E10, E11 and E15).
///
/// The argv starts from the Workflow builders the recorded commands use,
/// `ClassificationCLIInvocationBuilder` and `EsVirituCLIInvocationBuilder`. The route names the
/// project with `--project` in place of the output folder, so the command makes
/// `Analyses/<tool>[-batch]-<timestamp>/` as the in-process route does (E1), adds `--batch` for several
/// samples (E8) and `--format json`, and keeps the builder's `--db-digest` for a Kraken2 database
/// whose registry entry holds a SHA-256 (E9). The row records this argv, the one the transport
/// runs.
struct ClassifierCLIRouteLaunch: Sendable, Equatable {
    let tool: CLIClassifierTool
    /// The argv after `lungfish-cli`.
    let arguments: [String]
    /// Today's row title and first detail.
    let title: String
    let firstDetail: String
    /// Today's sample ids in plan order, which batch lines carry.
    let sampleIDs: [String]
    /// Whether the run ends in the read extraction sheet, as today's Kraken2 extract goal does.
    let extractsReads: Bool

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

    /// The title of the alert after a failed run, today's for the tool and path.
    var failureAlertTitle: String {
        switch (tool, isBatch) {
        case (.kraken2, false): return AppDelegate.classificationFailedAlertTitle
        case (.kraken2, true): return AppDelegate.classificationBatchFailedAlertTitle
        case (.esViritu, false): return AppDelegate.esVirituFailedAlertTitle
        case (.esViritu, true): return AppDelegate.esVirituBatchFailedAlertTitle
        }
    }

    /// The name `canWriteProjectOutputs` shows when the project is read-only, today's.
    var workflowName: String {
        switch (tool, isBatch) {
        case (.kraken2, false): return "Classification"
        case (.kraken2, true): return "Classification batch"
        case (.esViritu, false): return "EsViritu detection"
        case (.esViritu, true): return "EsViritu batch"
        }
    }

    // MARK: - Kraken2

    /// The launch of the Kraken2 `configs` into `projectURL`, or nil for no config.
    static func kraken2(configs: [ClassificationConfig], projectURL: URL) -> ClassifierCLIRouteLaunch? {
        guard let first = configs.first else { return nil }
        let isBatch = configs.count > 1
        var options = Array(ClassificationCLIInvocationBuilder.build(for: first).arguments.dropFirst(2))
        let firstInputs = (first.originalInputFiles ?? first.inputFiles).map(\.path)
        let inputsAtEnd = options.count >= firstInputs.count && Array(options.suffix(firstInputs.count)) == firstInputs
        if inputsAtEnd {
            options.removeLast(firstInputs.count)
        }
        options = replacing("--output-dir", in: options, with: ["--project", projectURL.path])
        if isBatch {
            // `--batch` pairs each sample's files by their names and plans its read set itself.
            options = removing("--paired", valueCount: 0, from: options)
            options = removing("--read-format", valueCount: 1, from: options)
            options = removing("--unpaired", valueCount: 1, from: options)
        }
        var inputs = inputsAtEnd ? firstInputs : []
        if isBatch {
            inputs += configs.dropFirst().flatMap { ($0.originalInputFiles ?? $0.inputFiles).map(\.path) }
            options.append("--batch")
        }
        let goalLabel: String
        switch first.goal {
        case .classify: goalLabel = "Classifying"
        case .profile: goalLabel = "Profiling"
        case .extract: goalLabel = "Classifying (extract)"
        }
        let sampleCount = configs.count
        return ClassifierCLIRouteLaunch(
            tool: .kraken2,
            arguments: ["kraken2", "classify"] + options + ["--format", "json"] + inputs,
            title: isBatch
                ? "Classification Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))"
                : "\(goalLabel) \(first.inputFiles.first?.lastPathComponent ?? "reads")",
            firstDetail: isBatch ? "Starting Kraken2/Bracken batch\u{2026}" : "Starting Kraken2 with \(first.databaseName)...",
            sampleIDs: configs.enumerated().map { index, config in kraken2SampleID(config, index: index) },
            extractsReads: !isBatch && first.goal == .extract
        )
    }

    /// Today's sample id of a Kraken2 batch sample, the name of the sample folder the wizard chose.
    private static func kraken2SampleID(_ config: ClassificationConfig, index: Int) -> String {
        let outputName = config.outputDirectory.lastPathComponent
        if !outputName.isEmpty {
            return MetagenomicsSampleGrouper.sanitizeSampleId(outputName)
        }
        if let firstInput = config.inputFiles.first {
            return MetagenomicsSampleGrouper.sanitizeSampleId(firstInput.deletingPathExtension().lastPathComponent)
        }
        return "sample_\(index + 1)"
    }

    // MARK: - EsViritu

    /// The launch of the EsViritu `configs` into `projectURL`, or nil for no config.
    static func esViritu(configs: [EsVirituConfig], projectURL: URL) -> ClassifierCLIRouteLaunch? {
        guard let first = configs.first else { return nil }
        let isBatch = configs.count > 1
        var options = EsVirituCLIInvocationBuilder.esVirituDetectCLIArguments(for: first)
        options = replacing("--output", in: options, with: ["--project", projectURL.path])
        if isBatch {
            // `--batch` takes every sample's inputs after one `--input`, names each sample by
            // its files and plans its read set itself, so it takes no `--sample` or read format.
            let settings = removing(
                "--read-format",
                valueCount: 1,
                from: removing("--sample", valueCount: 1, from: removingInputs(from: options))
            )
            let inputs = removing("--sample", valueCount: 1, from: EsVirituCLIInvocationBuilder.esVirituBatchCLIArguments(for: configs))
            options = inputs + ["--batch"] + settings
        }
        let sampleCount = configs.count
        return ClassifierCLIRouteLaunch(
            tool: .esViritu,
            arguments: ["esviritu", "detect"] + options + ["--format", "json"],
            title: isBatch
                ? "EsViritu Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))"
                : "EsViritu \(first.sampleName)",
            firstDetail: isBatch ? "Starting EsViritu batch\u{2026}" : "Starting EsViritu viral detection\u{2026}",
            sampleIDs: configs.map { MetagenomicsSampleGrouper.sanitizeSampleId($0.sampleName) },
            extractsReads: false
        )
    }

    // MARK: - Argv edits

    /// `arguments` with `option` and its value replaced by `replacement`, or with `replacement`
    /// added when `option` is missing.
    private static func replacing(_ option: String, in arguments: [String], with replacement: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
            return arguments + replacement
        }
        var edited = arguments
        edited.replaceSubrange(index...(index + 1), with: replacement)
        return edited
    }

    /// `arguments` without each `option` and the `valueCount` values after it.
    private static func removing(_ option: String, valueCount: Int, from arguments: [String]) -> [String] {
        var edited: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == option {
                index += 1 + valueCount
            } else {
                edited.append(arguments[index])
                index += 1
            }
        }
        return edited
    }

    /// `arguments` without `--input` and the paths after it, up to the next option.
    private static func removingInputs(from arguments: [String]) -> [String] {
        guard let start = arguments.firstIndex(of: "--input") else { return arguments }
        let end = arguments[(start + 1)...].firstIndex { $0.hasPrefix("--") } ?? arguments.endIndex
        var edited = arguments
        edited.removeSubrange(start..<end)
        return edited
    }
}

extension AppDelegate {
    // MARK: - Launch

    /// Runs the Kraken2 `configs` through `lungfish-cli kraken2 classify` with today's row,
    /// progress, labels and end of run (E15). A launch with no project open is refused with the
    /// `No Project Open` sheet and starts nothing (decision L1).
    func runClassificationThroughCLI(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        cliURLOverride: URL? = nil
    ) {
        guard !configs.isEmpty else { return }
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL else {
            refuseClassifierLaunchWithoutProject(
                tool: FASTQOperationToolID.kraken2.title,
                viewerController: viewerController,
                routeContext: routeContext
            )
            return
        }
        guard let launch = ClassifierCLIRouteLaunch.kraken2(configs: configs, projectURL: projectURL) else { return }
        runClassifierThroughCLI(launch, viewerController: viewerController, routeContext: routeContext, cliURLOverride: cliURLOverride)
    }

    /// Runs the EsViritu `configs` through `lungfish-cli esviritu detect` with today's row,
    /// progress, labels and end of run (E15). A launch with no project open is refused with the
    /// `No Project Open` sheet and starts nothing (decision L1).
    func runEsVirituThroughCLI(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        cliURLOverride: URL? = nil
    ) {
        guard !configs.isEmpty else { return }
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL else {
            refuseClassifierLaunchWithoutProject(
                tool: FASTQOperationToolID.esViritu.title,
                viewerController: viewerController,
                routeContext: routeContext
            )
            return
        }
        guard let launch = ClassifierCLIRouteLaunch.esViritu(configs: configs, projectURL: projectURL) else { return }
        runClassifierThroughCLI(launch, viewerController: viewerController, routeContext: routeContext, cliURLOverride: cliURLOverride)
    }

    /// Registers the CLI route's row with today's title and first detail and the argv the
    /// transport runs, and calls `start` only when the row started. Like today's rows it locks no
    /// bundle, so a real `OperationCenter` never refuses it.
    @discardableResult
    static func beginClassifierCLIRouteOperation(
        _ launch: ClassifierCLIRouteLaunch,
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

    private func runClassifierThroughCLI(
        _ launch: ClassifierCLIRouteLaunch,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?,
        cliURLOverride: URL?
    ) {
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: launch.workflowName
        ) else { return }
        let runner = CLIClassifierRunner(cliURLOverride: cliURLOverride)
        let request = CLIClassifierRunRequest(tool: launch.tool, arguments: launch.arguments, sampleIDs: launch.sampleIDs)
        Self.beginClassifierCLIRouteOperation(launch, routeContext: routeContext) { operationID in
            Task { @MainActor [weak self] in
                do {
                    let completion = try await runner.run(request, operationID: operationID) { line in
                        viewerController.showProgress(line)
                    }
                    Self.finishClassifierThroughCLI(
                        completion,
                        launch: launch,
                        operationID: operationID,
                        viewerController: viewerController,
                        routeContext: routeContext,
                        appDelegate: self
                    )
                } catch is CancellationError {
                    viewerController.hideProgress()
                    OperationCenter.shared.acknowledgeCancellation(id: operationID)
                } catch {
                    let failure = error as? CLIClassifierFailure
                        ?? CLIClassifierFailure(message: error.localizedDescription, errorMessage: nil, errorDetail: nil)
                    Self.failClassifierThroughCLI(
                        failure,
                        launch: launch,
                        operationID: operationID,
                        viewerController: viewerController,
                        routeContext: routeContext,
                        appDelegate: self
                    )
                }
            }
            OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }
        }
    }

    // MARK: - End of run

    /// Completes the row with today's label and detail and ends the run as the in-process route does
    /// for the tool (UX D15). The command wrote the result, its records and the source bundle
    /// entries, so nothing is written here. The row finishes whether or not the app delegate
    /// that launched the run is still there.
    private static func finishClassifierThroughCLI(
        _ completion: CLIClassifierCompletion,
        launch: ClassifierCLIRouteLaunch,
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
        if let problem = completion.readBackProblem {
            OperationCenter.shared.log(id: operationID, level: .warning, message: problem)
        }
        let completed = completion.completesWithWarning
            ? OperationCenter.shared.completeWithWarning(id: operationID, detail: completion.detail)
            : OperationCenter.shared.complete(id: operationID, detail: completion.detail)
        guard completed else { return }

        let sidebar = appDelegate?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?.sidebarController
        switch (launch.tool, launch.isBatch) {
        case (.kraken2, false):
            if let result = completion.taxonomyResult {
                viewerController.displayTaxonomyResult(result)
                if launch.extractsReads, let folder = completion.folder {
                    presentReadExtraction(for: result, folder: folder, viewerController: viewerController, routeContext: routeContext)
                }
            }
            // The viewport already shows the result, so the sidebar selects its row.
            if let folder = completion.folder {
                sidebar?.reloadAndRevealItem(forURL: folder)
            }
        case (.kraken2, true):
            if let result = completion.taxonomyResult {
                viewerController.displayTaxonomyResult(result)
            }
            sidebar?.requestReloadFromFilesystem()
        case (.esViritu, _):
            // Nothing opens. The user picks the new result in the sidebar.
            sidebar?.requestReloadFromFilesystem()
        }
    }

    /// Today's extract goal opens the read extraction sheet on the dominant species.
    private static func presentReadExtraction(
        for result: ClassificationResult,
        folder: URL,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?
    ) {
        guard viewerController.taxonomyViewController != nil,
              let topSpecies = result.tree.dominantSpecies,
              let window = viewerController.view.window else { return }
        let context = TaxonomyReadExtractionAction.Context(
            tool: .kraken2,
            resultPath: folder,
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [topSpecies.taxId])],
            suggestedName: "kraken2_\(topSpecies.name.replacingOccurrences(of: " ", with: "_"))",
            routeContext: routeContext
        )
        TaxonomyReadExtractionAction.shared.present(context: context, hostWindow: window)
    }

    /// Fails the row with the command's message and shows today's alert. The command keeps the
    /// failed folder hidden with its records (E5), so nothing is removed here.
    private static func failClassifierThroughCLI(
        _ failure: CLIClassifierFailure,
        launch: ClassifierCLIRouteLaunch,
        operationID: UUID,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?,
        appDelegate: AppDelegate?
    ) {
        viewerController.hideProgress()
        if launch.tool == .esViritu, !launch.isBatch {
            OperationCenter.shared.log(id: operationID, level: .error, message: failure.message)
        }
        guard OperationCenter.shared.fail(
            id: operationID,
            detail: failure.message,
            errorMessage: failure.errorMessage,
            errorDetail: failure.errorDetail
        ) else { return }
        if launch.tool == .kraken2, launch.isBatch {
            appDelegate?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                .sidebarController.requestReloadFromFilesystem()
        }
        let alert = NSAlert()
        alert.messageText = launch.failureAlertTitle
        alert.informativeText = failure.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = viewerController.view.window {
            alert.beginSheetModal(for: window)
        }
    }
}
