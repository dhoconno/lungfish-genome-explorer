// AppDelegate+ProvenanceExportOperationBegin.swift - The Operations row of the provenance report export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishWorkflow

extension AppDelegate {
    /// What the alert after a provenance export says. The words are the ones the in-process write showed, with the
    /// leaf's message where the exporter's error was.
    struct ProvenanceExportSummary: Equatable {
        enum Style: Equatable {
            case informational
            case warning
        }

        let title: String
        let message: String
        let style: Style
        /// The primary artifact a successful export offers to reveal in Finder.
        let revealURL: URL?
    }

    /// The failure alert, for the leaf's message or a refusal the view found before it began a row.
    static func provenanceExportFailureSummary(_ message: String) -> ProvenanceExportSummary {
        ProvenanceExportSummary(title: "Export Failed", message: message, style: .warning, revealURL: nil)
    }

    /// The alert after a row ended, or nil after a cancel, which reads Cancelled in the Operations panel and shows
    /// nothing (UX 4).
    static func provenanceExportSummary(
        format: ProvenanceExportFormat,
        outcome: CLIViewerExportRunner.Outcome
    ) -> ProvenanceExportSummary? {
        switch outcome {
        case .completed(let primaryArtifactURL):
            return ProvenanceExportSummary(
                title: "Provenance Export Complete",
                message: "\(format.rawValue) exported to \(primaryArtifactURL.lastPathComponent).",
                style: .informational,
                revealURL: primaryArtifactURL
            )
        case .cancelled:
            return nil
        case .failed(let failure):
            return provenanceExportFailureSummary(failure.message)
        }
    }

    /// Begins the Operations row of one provenance report export and runs `lungfish-cli provenance export` for it on
    /// the shared viewer export runner (Phase 2.12 lane 12.38, ARCH ruling 1.5, rules 3 and 4). File > Export >
    /// Provenance and the Inspector's export menu both come here.
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-process export took none. The leaf writes
    /// the report folder and its record, and the app writes no byte after it exits. A failure fails the row and
    /// reaches `onFailure`. A cancel reads Cancelled and shows nothing.
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from ``ProvenanceReportExport/invocation(inputURL:format:outputDirectory:allowUnpinned:)``.
    ///   - format: The report format, which names the primary artifact the row links.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not start.
    @discardableResult
    static func beginProvenanceExportOperation(
        invocation: ViewerExportInvocation,
        format: ProvenanceExportFormat,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputDirectory = URL(fileURLWithPath: invocation.output, isDirectory: true)
        let primaryArtifactURL = outputDirectory.appendingPathComponent(
            ProvenanceReportExport.primaryArtifactFileName(for: format)
        )
        let start = reporter.begin(
            title: "Export Provenance",
            detail: "Writing \(outputDirectory.lastPathComponent)",
            operationType: .export,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: invocation.commandPath.joined(separator: " "),
                args: Array(arguments.dropFirst(invocation.commandPath.count))
            ),
            onCancel: { runner.cancel() }
        )
        guard case .started(let operationID) = start else { return nil }
        return (operationID, Task { @MainActor in
            let outcome = await runner.run(
                arguments: arguments,
                outputURL: primaryArtifactURL,
                operationID: operationID,
                completionDetail: "Exported \(primaryArtifactURL.lastPathComponent)",
                emitsEvents: invocation.emitsEvents,
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }

    /// Runs the export the save panel chose for, from either entry point. The view keeps the pin gate sheet, the save
    /// panel and the check that the chosen path is not a file. This begins the row, and shows the alert when the
    /// leaf ended.
    ///
    /// - Parameters:
    ///   - request: What the export describes, with the format.
    ///   - allowUnpinned: True only when the pin gate sheet's Export Anyway… answered.
    ///   - outputDirectory: The folder the save panel returned.
    ///   - window: The window the alert sheets attach to.
    /// - Returns: The row's id and the task that settles the row and shows the alert, or nil when nothing started.
    @MainActor
    @discardableResult
    static func runProvenanceExport(
        request: ProvenanceExportRequest,
        allowUnpinned: Bool,
        outputDirectory: URL,
        window: NSWindow,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared
    ) -> (operationID: UUID, task: Task<Void, Never>)? {
        let format = request.format
        let invocation = ProvenanceReportExport.invocation(
            inputURL: request.selectedURL, format: format, outputDirectory: outputDirectory, allowUnpinned: allowUnpinned
        )
        guard let begun = beginProvenanceExportOperation(
            invocation: invocation, format: format, runner: runner, reporter: reporter, onFailure: { _ in }
        ) else {
            presentProvenanceExportSummary(provenanceExportFailureSummary("The export could not start."), window: window)
            return nil
        }
        let settled = Task { @MainActor in
            let outcome = await begun.task.value
            if let summary = provenanceExportSummary(format: format, outcome: outcome) {
                presentProvenanceExportSummary(summary, window: window)
            }
        }
        return (begun.operationID, settled)
    }

    /// Shows `summary` as a sheet, with Show in Finder when it names a file to reveal.
    @MainActor
    static func presentProvenanceExportSummary(_ summary: ProvenanceExportSummary, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.message
        alert.alertStyle = summary.style == .informational ? .informational : .warning
        alert.addButton(withTitle: "OK")
        if summary.revealURL != nil {
            alert.addButton(withTitle: "Show in Finder")
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, let revealURL = summary.revealURL {
                NSWorkspace.shared.activateFileViewerSelecting([revealURL])
            }
        }
    }
}
