// BlastResultsDrawerTab+ExportOperationBegin.swift - The Operations row of the BLAST drawer's table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension BlastResultsDrawerTab {
    /// Begins the Operations row of the table export and runs `lungfish-cli blast export table` for it on the shared
    /// viewer export runner (Phase 2.12 lane 12.33, ARCH ruling T5 condition 3, rules 3 and 4 of ruling 1.5).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the drawer's export took none. The leaf writes
    /// the file and its record, and the app writes no byte after it exits. A failure ends the row failed (the drawer
    /// only logged it before, UX 4) and reaches `onFailure`, which shows the failure alert. A cancel reads
    /// Cancelled and shows nothing.
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation for the file the drawer's result was read from, from
    ///     ``BlastVerificationTableExport/invocation(recordURL:format:outputURL:force:emitsEvents:)``.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginBlastTableExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export BLAST Table",
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
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }
}
