// AppDelegate+RNASeqLinuxRun.swift - The RNA-seq plan sheets and the adopt of a Linux run (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Import Center opens the bulk plan sheet and the 10x plan sheet without a panel, since a plan needs no project, and
// the adopt sheet after an open panel. Each sheet builds the argv of its CLI command once (`RNASeqPlanSheetModel`,
// `RNASeqAdoptSheetModel`), this file registers the Operations row with that argv and runs it, and the row ends when the
// command ends. A plan runs `lungfish-cli rnaseq quant --write-plan` or `rnaseq solo-plan`, which print one summary and no
// event stream, so they run on `CLIProcessLauncher` as the quantify row does. The adopt runs `import rnaseq --adopt` on
// `CLIImportRunner`, whose events it prints. Both rows carry the FASTQ plan and adopt `OperationType`, `.ingestion`
// (`FASTQIngestionService+LinuxRun.swift`). A refusal reaches the row and the sheet in the command's own words.

import AppKit
import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import SwiftUI
import os

// MARK: - The plan runner

/// Runs the argv of a plan and ends when the command ends. A stand-in conforms in tests.
protocol RNASeqPlanCommandRunning: Sendable {
    func run(argv: [String], cancellation: CLIRunCancellation, log: @escaping @Sendable (String) -> Void) async throws
}

enum RNASeqPlanRunError: Error, Equatable, LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case cancelled
    /// The command's own words, from its standard error.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "The lungfish-cli command was not found next to the app."
        case .launchFailed(let reason): return "The plan could not start. \(reason)"
        case .cancelled: return "The plan was cancelled. No plan folder was written."
        case .failed(let words): return words
        }
    }
}

/// Runs `lungfish-cli` on ``CLIProcessLauncher``. A cancel gives the command SIGTERM and the grace of an operation, and the
/// command's own cancel removes any folder it began (`rnaseq quant --write-plan` and `rnaseq solo-plan`).
struct CLIRNASeqPlanRunner: RNASeqPlanCommandRunning {
    private let cliURLProvider: @Sendable () -> URL?
    private let environmentAdditions: [String: String]

    init(
        cliURLProvider: @escaping @Sendable () -> URL? = { LungfishCLIRunner.findCLI() },
        environmentAdditions: [String: String] = [:]
    ) {
        self.cliURLProvider = cliURLProvider
        self.environmentAdditions = environmentAdditions
    }

    /// The command's words from its standard error: the text after the first `Error: `, or the text as written.
    static func words(fromStandardError text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "Error: ") else { return trimmed }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func run(argv: [String], cancellation: CLIRunCancellation, log: @escaping @Sendable (String) -> Void) async throws {
        guard let cliURL = cliURLProvider() else { throw RNASeqPlanRunError.cliNotFound }
        let spec = CLIProcessLauncher.spec(
            executableURL: cliURL,
            arguments: argv,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            environmentAdditions: environmentAdditions
        )
        let outcome = await CLIProcessLauncher.run(
            spec,
            cancellation: cancellation,
            onStdoutLine: { _ in },
            onStderrLine: { log($0) }
        )
        switch outcome {
        case .launchFailed(let reason):
            throw RNASeqPlanRunError.launchFailed(reason)
        case .cancelled:
            throw RNASeqPlanRunError.cancelled
        case .exited(let exit):
            if Task.isCancelled { throw RNASeqPlanRunError.cancelled }
            guard exit.status == 0 else {
                let words = Self.words(fromStandardError: "\(exit.stderr)")
                throw RNASeqPlanRunError.failed(words.isEmpty ? "The plan stopped with status \(exit.status)." : words)
            }
        }
    }
}

extension AppDelegate {
    // MARK: - The sheets

    /// Opens the plan sheet of a card (Import Center, RNA-seq Plan for a Linux Machine and Single-cell Plan for a Linux
    /// Machine). The plan needs no project, since nothing is imported.
    func launchRNASeqPlanSheet(_ kind: RNASeqPlanKind, _ request: ImportWizardRequest) {
        guard let controller = activeMainWindowController(), let window = controller.window else { return }
        let model = RNASeqPlanSheetModel(kind: kind)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = model.title
        panel.isReleasedWhenClosed = false
        model.start = { request, completion in
            Self.startRNASeqPlan(request: request, routeContext: nil, completion: completion)
        }
        model.cancelRun = { OperationCenter.shared.cancel(id: $0) }
        model.onDismiss = { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
        panel.contentViewController = NSHostingController(rootView: RNASeqPlanSheet(model: model))
        panel.setContentSize(NSSize(width: 640, height: kind == .bulk ? 660 : 780))
        window.beginSheet(panel)
        request.presented()
    }

    /// Opens the adopt sheet for the returned folder chosen in the card's open panel (Import Center, RNA-seq Linux Run
    /// Result). The adopt writes a result into the open project's Analyses folder, so a project must be open.
    func adoptRNASeqRunFromURL(_ url: URL) {
        guard let controller = activeMainWindowController(),
              let window = controller.window,
              let mainSplit = controller.mainSplitViewController,
              let projectURL = mainSplit.sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Open a project before adopting the counts of a Linux run.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope,
            workflowName: "RNA-seq Linux run adopt",
            presentingWindow: window
        ) else { return }

        let routeContext = currentOperationRouteContext(for: controller)
        let model = RNASeqAdoptSheetModel(folder: url, projectURL: projectURL)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Adopt a Linux Run of RNA-seq Counts"
        panel.isReleasedWhenClosed = false
        model.start = { request, completion in
            Self.startRNASeqAdopt(request: request, routeContext: routeContext, completion: completion)
        }
        model.cancelRun = { OperationCenter.shared.cancel(id: $0) }
        // The adopted result is selected in the sidebar, as an import's result is.
        model.onAdopted = { [weak mainSplit] bundle in mainSplit?.refreshSidebarAndSelectDerivedURL(bundle) }
        model.onDismiss = { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
        panel.contentViewController = NSHostingController(rootView: RNASeqAdoptSheet(model: model))
        panel.setContentSize(NSSize(width: 580, height: 400))
        window.beginSheet(panel)
    }

    // MARK: - The plan row

    /// Registers the row of a plan and, only when it starts, calls `launch` with the operation ID. The row records
    /// `request.arguments`, the argv the run executes, and carries the `OperationType` of the FASTQ plan.
    @discardableResult
    static func beginRNASeqPlanOperation(
        request: RNASeqPlanRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let name = request.planFolder.lastPathComponent
        let result = reporter.begin(
            title: request.dryRun ? "Check of the Plan: \(name)" : "Plan for a Linux Machine: \(name)",
            detail: request.dryRun ? "Checking the plan\u{2026}" : "Writing the plan\u{2026}",
            operationType: .ingestion,
            cliCommand: CLIImportRunner.commandLine(arguments: request.arguments),
            routeContext: routeContext
        )
        if case .started(let operationID) = result { launch(operationID) }
        return result
    }

    /// Starts the row and the run of a plan, with the row's Cancel stopping the command. `completion` is called on the main
    /// actor once the row has ended. Returns the row's id, or nil when `begin` refused it.
    @MainActor
    @discardableResult
    static func startRNASeqPlan(
        request: RNASeqPlanRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        runner: any RNASeqPlanCommandRunning = CLIRNASeqPlanRunner(),
        completion: @escaping @MainActor (RNASeqPlanOutcome) -> Void
    ) -> UUID? {
        beginRNASeqPlanOperation(request: request, routeContext: routeContext, reporter: reporter) { operationID in
            let cancellation = CLIRunCancellation()
            let task = Task { @MainActor in
                let outcome = await runRNASeqPlan(
                    request: request, operationID: operationID, reporter: reporter, runner: runner, cancellation: cancellation
                )
                completion(outcome)
            }
            reporter.setCancelCallback(for: operationID) {
                cancellation.cancel()
                task.cancel()
            }
        }.startedID
    }

    /// Runs the plan and ends its row: Completed with the plan folder's name, Cancelled when no folder was written, or
    /// Failed with the command's words.
    @MainActor
    static func runRNASeqPlan(
        request: RNASeqPlanRequest,
        operationID: UUID,
        reporter: any OperationReporting,
        runner: any RNASeqPlanCommandRunning,
        cancellation: CLIRunCancellation
    ) async -> RNASeqPlanOutcome {
        let (lines, lineSink) = AsyncStream<String>.makeStream()
        let logger = Task { @MainActor in
            for await line in lines { reporter.log(id: operationID, level: .info, message: line) }
        }
        let name = request.planFolder.lastPathComponent
        do {
            try await runner.run(argv: request.arguments, cancellation: cancellation) { lineSink.yield($0) }
            lineSink.finish()
            await logger.value
            if request.dryRun {
                _ = reporter.complete(
                    id: operationID, detail: "Checked \(name). The command made every refusal and wrote no folder.", outputURLs: []
                )
                return .checked
            }
            _ = reporter.complete(id: operationID, detail: "Plan written to \(name)", outputURLs: [request.planFolder])
            return .written(request.planFolder)
        } catch RNASeqPlanRunError.cancelled {
            lineSink.finish()
            await logger.value
            _ = reporter.acknowledgeCancellation(id: operationID, detail: "Cancelled. No plan folder was written.")
            return .cancelled
        } catch {
            lineSink.finish()
            await logger.value
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            reporter.log(id: operationID, level: .error, message: words)
            _ = reporter.fail(id: operationID, detail: words, errorMessage: words)
            return .refused(words)
        }
    }

    // MARK: - The adopt row

    /// Registers the row of the adopt and, only when it starts, calls `launch` with the operation ID. The row records
    /// `request.arguments` and carries the `OperationType` of the FASTQ adopt. The result's name comes from the sheet, so the
    /// row locks no bundle.
    @discardableResult
    static func beginRNASeqAdoptOperation(
        request: RNASeqAdoptRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let name = request.folder.lastPathComponent
        let result = reporter.begin(
            title: request.dryRun ? "Check of the Adopt: \(name)" : "RNA-seq Linux Run Result: \(name)",
            detail: "Checking the returned folder\u{2026}",
            operationType: .ingestion,
            cliCommand: CLIImportRunner.commandLine(arguments: request.arguments),
            routeContext: routeContext
        )
        if case .started(let operationID) = result { launch(operationID) }
        return result
    }

    /// Starts the row and the run of the adopt, with the row's Cancel stopping the command. `completion` is called on the
    /// main actor once the row has ended. Returns the row's id, or nil when `begin` refused it.
    @MainActor
    @discardableResult
    static func startRNASeqAdopt(
        request: RNASeqAdoptRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        runner: CLIImportRunner = CLIImportRunner(),
        completion: @escaping @MainActor (RNASeqAdoptOutcome) -> Void
    ) -> UUID? {
        beginRNASeqAdoptOperation(request: request, routeContext: routeContext, reporter: reporter) { operationID in
            let task = Task.detached {
                let outcome = await runRNASeqAdopt(request: request, operationID: operationID, runner: runner)
                await MainActor.run { completion(outcome) }
            }
            reporter.setCancelCallback(for: operationID) {
                task.cancel()
                runner.cancel()
            }
        }.startedID
    }

    /// How the adopt ends for what the runner reported. A run with no error ends in the result the command named, or in a
    /// passed check for a `--dry-run`, which names none. The two cancel messages are the words `CLIImportRunner.run` gives
    /// `onError`, and any other message is the command's own words, which the runner has put on the row already.
    nonisolated static func rnaSeqAdoptEnd(_ seen: RNASeqImportSeen, dryRun: Bool) -> RNASeqAdoptOutcome {
        if let error = seen.error {
            let cancelled = error == "Import cancelled" || error == "Import cancelled before it started"
            return cancelled ? .cancelled : .refused(error)
        }
        if dryRun { return .checked }
        guard let bundle = seen.bundles.last else {
            return .refused("The adopt finished without naming the result it made.")
        }
        return .adopted(bundle)
    }

    /// Runs `import rnaseq --adopt` and ends its row. The row completes with the result's name, is acknowledged as cancelled
    /// after a cancel, or is failed with the command's words, which the runner puts on it. The hop to the main actor waits
    /// for the main actor, so the row ends after every event the runner handed over before it.
    nonisolated static func runRNASeqAdopt(
        request: RNASeqAdoptRequest,
        operationID: UUID,
        runner: CLIImportRunner
    ) async -> RNASeqAdoptOutcome {
        let seen = OSAllocatedUnfairLock(initialState: RNASeqImportSeen())
        await runner.run(
            arguments: request.arguments,
            operationID: operationID,
            projectDirectory: request.projectURL,
            onBundleCreated: { bundle in seen.withLock { $0.bundles.append(bundle) } },
            onError: { message in seen.withLock { $0.error = message } }
        )
        let reported = seen.withLock { $0 }
        let end = rnaSeqAdoptEnd(reported, dryRun: request.dryRun)
        let folder = request.folder.lastPathComponent
        await MainActor.run {
            switch end {
            case .adopted(let bundle):
                _ = OperationCenter.shared.complete(
                    id: operationID, detail: "Adopted \(folder) as \(bundle.lastPathComponent)", bundleURLs: [bundle]
                )
            case .checked:
                _ = OperationCenter.shared.complete(
                    id: operationID, detail: "Checked \(folder). Every check passed and nothing was imported.", bundleURLs: []
                )
            case .cancelled:
                _ = OperationCenter.shared.acknowledgeCancellation(id: operationID, detail: "Cancelled")
            case .refused(let words):
                // The runner failed the row with the command's words already. A finish with no result is failed here.
                if reported.error == nil { _ = OperationCenter.shared.fail(id: operationID, detail: words, errorMessage: words) }
            }
        }
        return end
    }
}
