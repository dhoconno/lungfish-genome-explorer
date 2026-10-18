// NaoMgsResultViewController+ExportOperationBegin.swift - The Operations row of the NAO-MGS table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

extension NaoMgsResultViewController {
    /// Begins the Operations row of the table export and runs `lungfish-cli nao-mgs export table` for it on the
    /// shared viewer export runner (Phase 2.12 lane 12.31 M4, ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-app export took none. The leaf writes the
    /// file and its record, and the app writes no byte after it exits. A failure fails the row and reaches
    /// `onFailure`, which shows today's alert. A cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation for the view's state, from `NaoMgsSummaryExport.invocation`.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginNaoMgsTableExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export NAO-MGS Summary",
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
                completionDetail: "Exported \(outputURL.lastPathComponent)"
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }
}
