// AppDelegate+ImportCenterRNASeq.swift - The Import Center's two RNA-seq cards: the sheet, the Operations row and the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.4 lane RS-GLUE. The bulk card and the single-cell card each open a sheet (`RNASeqBulkImportSheet`,
// `RNASeqSingleCellImportSheet`). The sheet builds the argv of `lungfish-cli import rnaseq` once
// (`CLIImportRunner.buildRNASeqImportArguments`). This file registers the Operations row with that argv, runs it on
// `CLIImportRunner` as the FASTQ imports do, ends the row, and selects the `.lungfishrnaseq` folder in the sidebar. A
// refusal of the command reaches the row and the sheet in the command's own words, and a cancel stops the command,
// which removes its stage (`docs/formats/rnaseq-bundle.md`, The one writer).

import AppKit
import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import SwiftUI
import os

/// What `CLIImportRunner.run` reported of one `import rnaseq` run, through `onBundleCreated` and `onError`.
struct RNASeqImportSeen: Sendable, Equatable {
    var bundles: [URL] = []
    var error: String?
}

/// How the row of a finished `import rnaseq` run ends.
enum RNASeqImportEnd: Sendable, Equatable {
    /// The command made this result.
    case completed(URL)
    /// The command stopped after a cancel, so the row is acknowledged as cancelled.
    case cancelled
    /// The command refused or failed, and the runner already failed the row with the command's message.
    case failedByRunner(String)
    /// The command finished and named no result, so the row is failed here.
    case noBundle(String)

    var outcome: RNASeqImportOutcome {
        switch self {
        case .completed(let url): return .imported(url)
        case .cancelled: return .cancelled
        case .failedByRunner(let words), .noBundle(let words): return .refused(words)
        }
    }
}

extension AppDelegate {
    // MARK: - The sheet

    /// Opens the sheet of an RNA-seq card for the inputs chosen in its open panel (Import Center, RNA-seq Counts and
    /// Single-cell Counts). The import writes into the open project's Analyses folder, so a project must be open.
    func importRNASeqFromURLs(_ urls: [URL], kind: RNASeqImportKind) {
        guard let controller = activeMainWindowController(),
              let window = controller.window,
              let mainSplit = controller.mainSplitViewController,
              let projectURL = mainSplit.sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Open a project before importing RNA-seq counts.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope,
            workflowName: "RNA-seq import",
            presentingWindow: window
        ) else { return }

        let routeContext = currentOperationRouteContext(for: controller)
        let model = RNASeqImportSheetModel(kind: kind, inputs: urls, projectURL: projectURL)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = kind == .bulk ? "Import RNA-seq Counts" : "Import Single-cell Counts"
        panel.isReleasedWhenClosed = false
        model.start = { request, completion in
            Self.startRNASeqImport(request: request, routeContext: routeContext, completion: completion)
        }
        model.cancelRun = { OperationCenter.shared.cancel(id: $0) }
        model.onImported = { [weak mainSplit] bundle in mainSplit?.refreshSidebarAndSelectDerivedURL(bundle) }
        model.onDismiss = { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
        switch kind {
        case .bulk:
            panel.contentViewController = NSHostingController(rootView: RNASeqBulkImportSheet(model: model))
            panel.setContentSize(NSSize(width: 580, height: 440))
        case .singleCell:
            panel.contentViewController = NSHostingController(rootView: RNASeqSingleCellImportSheet(model: model))
            panel.setContentSize(NSSize(width: 580, height: 560))
        }
        window.beginSheet(panel)
    }

    // MARK: - The row

    /// Registers the row of `import rnaseq` and, only when it starts, calls `launch` with the operation ID. The row
    /// records `request.arguments`, the argv the run executes, with the command's `--format json` as the other FASTQ
    /// imports do, and carries the same `OperationType` as the FASTQ import. The result's name comes from the command,
    /// so the row locks no bundle, and `begin` cannot refuse it on a real `OperationCenter` today.
    @discardableResult
    static func beginRNASeqImportOperation(
        request: RNASeqImportRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "RNA-seq Import: \(request.name)",
            detail: "Reading the inputs\u{2026}",
            operationType: .ingestion,
            cliCommand: CLIImportRunner.commandLine(arguments: request.arguments),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    // MARK: - The run

    /// Starts the row and the run for `request`, with the row's Cancel stopping the command. `completion` is called on
    /// the main actor once the row has ended. Returns the row's id, or nil when `begin` refused it.
    @MainActor
    static func startRNASeqImport(
        request: RNASeqImportRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        runner: CLIImportRunner = CLIImportRunner(),
        completion: @escaping @MainActor (RNASeqImportOutcome) -> Void
    ) -> UUID? {
        beginRNASeqImportOperation(request: request, routeContext: routeContext, reporter: reporter) { operationID in
            let task = Task.detached {
                let outcome = await runRNASeqImport(
                    arguments: request.arguments, operationID: operationID, projectDirectory: request.projectURL, runner: runner
                )
                await MainActor.run { completion(outcome) }
            }
            reporter.setCancelCallback(for: operationID) {
                task.cancel()
                runner.cancel()
            }
        }.startedID
    }

    /// How the row ends for what the runner reported. A run with no error ends in the result the command named. The two
    /// cancel messages are the words `CLIImportRunner.run` gives `onError` for a cancel before the launch and for a
    /// cancel of a run, and the runner leaves the row to its caller. Any other message is the command's own words, and
    /// the runner has failed the row with them already.
    nonisolated static func rnaSeqImportEnd(_ seen: RNASeqImportSeen) -> RNASeqImportEnd {
        if let error = seen.error {
            let cancelled = error == "Import cancelled" || error == "Import cancelled before it started"
            return cancelled ? .cancelled : .failedByRunner(error)
        }
        guard let bundle = seen.bundles.last else {
            return .noBundle("The import finished without naming the result it made.")
        }
        return .completed(bundle)
    }

    /// Runs `import rnaseq` with `arguments` for the row `operationID` and ends the row. The row completes with the
    /// result's name, is acknowledged as cancelled after a cancel, or is failed with the command's words, which the
    /// runner puts on it. The hop to the main actor waits for the main actor, so the row ends after every event the
    /// runner handed over before it.
    nonisolated static func runRNASeqImport(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        runner: CLIImportRunner
    ) async -> RNASeqImportOutcome {
        let seen = OSAllocatedUnfairLock(initialState: RNASeqImportSeen())
        await runner.run(
            arguments: arguments,
            operationID: operationID,
            projectDirectory: projectDirectory,
            onBundleCreated: { bundle in seen.withLock { $0.bundles.append(bundle) } },
            onError: { message in seen.withLock { $0.error = message } }
        )
        let end = rnaSeqImportEnd(seen.withLock { $0 })
        await MainActor.run {
            switch end {
            case .completed(let bundle):
                _ = OperationCenter.shared.complete(
                    id: operationID, detail: "Imported \(bundle.lastPathComponent)", bundleURLs: [bundle]
                )
            case .cancelled:
                _ = OperationCenter.shared.acknowledgeCancellation(id: operationID, detail: "Cancelled")
            case .failedByRunner:
                break
            case .noBundle(let words):
                _ = OperationCenter.shared.fail(id: operationID, detail: words)
            }
        }
        return end.outcome
    }
}
