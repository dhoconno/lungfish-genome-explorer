// AppDelegate+MetadataExportOperationBegin.swift - The Operations row of the folder and project metadata CSV export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension AppDelegate {
    /// What the alert after a failed metadata export says. The words are the ones the project export showed when it
    /// wrote the file in process, with the leaf's message where the file system's error was.
    struct MetadataExportAlert: Equatable {
        let title: String
        let message: String
    }

    static func metadataExportFailureAlert(_ message: String) -> MetadataExportAlert {
        MetadataExportAlert(title: "Export Failed", message: message)
    }

    /// Begins the Operations row of one metadata CSV export and runs `lungfish-cli metadata export --output` for it on
    /// the shared viewer export runner (Phase 2.12 lane 12.38, ARCH ruling 1.5, rules 3 and 4). The folder sheet and
    /// the project export both come here.
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no lock, as the in-process write took none. The leaf writes the file
    /// and its record, and the app writes no byte after it exits. A failure fails the row and reaches `onFailure`. A
    /// cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from ``FolderMetadataExport/invocation(folderURL:selectionURL:outputURL:force:emitsEvents:)``.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not start.
    @discardableResult
    static func beginMetadataExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export Sample Metadata",
            detail: "Writing \(outputURL.lastPathComponent)",
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
                outputURL: outputURL,
                operationID: operationID,
                completionDetail: "Exported \(outputURL.lastPathComponent)",
                emitsEvents: invocation.emitsEvents,
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }

    /// Runs the export of the samples a sheet holds at the click. It writes the selection file beside the output,
    /// begins the row and reports a failure through `onFailure`. It touches no sheet state, so the caller passes the
    /// samples it froze (ARCH ruling 1.3).
    ///
    /// - Parameters:
    ///   - folderURL: The folder the sheet is for. The leaf checks that it exists and reads the selection instead.
    ///   - samples: The samples in the order the sheet exports them, with the edits the user has not saved.
    ///   - outputURL: The file the user chose. The panel already confirmed a replace, so `--force` is passed only when
    ///     the file exists.
    ///   - onFailure: Called on the main actor with the message the alert shows, when the selection could not be
    ///     written or the leaf failed.
    /// - Returns: The row's id and the task that settles the row, or nil when nothing started.
    @MainActor
    @discardableResult
    static func runMetadataExport(
        folderURL: URL,
        samples: [FASTQSampleMetadata],
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let selectionURL: URL
        do {
            selectionURL = try FolderMetadataExport.selection(samples: samples).write(besideOutput: outputURL)
        } catch {
            onFailure(error.localizedDescription)
            return nil
        }
        let invocation = FolderMetadataExport.invocation(
            folderURL: folderURL,
            selectionURL: selectionURL,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
        let begun = beginMetadataExportOperation(
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: { failure in onFailure(failure.message) }
        )
        if begun == nil {
            onFailure("The export could not start.")
        }
        return begun
    }

    /// Shows the failure alert as a sheet on `window`, when the sheet has one.
    @MainActor
    static func presentMetadataExportFailure(_ message: String, window: NSWindow?) {
        let words = metadataExportFailureAlert(message)
        let alert = NSAlert()
        alert.messageText = words.title
        alert.informativeText = words.message
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        }
    }
}
