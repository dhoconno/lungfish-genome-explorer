// TaxTriageResultViewController+ExportOperationBegin.swift - The Operations rows of the TaxTriage exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

extension TaxTriageResultViewController {
    /// Begins the Operations row of the organism matrix export and runs `lungfish-cli taxtriage export
    /// organism-matrix` for it on the shared viewer export runner (Phase 2.12 lane 12.32, ARCH ruling 1.5).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation for the view's state, from `organismMatrixExportInvocation(outputURL:)`.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginTaxTriageOrganismMatrixExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        beginTaxTriageExportOperation(
            title: "Export TaxTriage Organism Matrix",
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: onFailure
        )
    }

    /// Begins the Operations row of the batch report export and runs `lungfish-cli taxtriage export batch-report`
    /// for it. The parameters and the result are those of `beginTaxTriageOrganismMatrixExportOperation`.
    @discardableResult
    static func beginTaxTriageBatchReportExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        beginTaxTriageExportOperation(
            title: "Export TaxTriage Batch Report",
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: onFailure
        )
    }

    /// Begins the Operations row of the results export and runs `lungfish-cli taxtriage export results` for it. The
    /// parameters and the result are those of `beginTaxTriageOrganismMatrixExportOperation`.
    @discardableResult
    static func beginTaxTriageResultsExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        beginTaxTriageExportOperation(
            title: "Export TaxTriage Results",
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: onFailure
        )
    }

    /// The row every TaxTriage export begins. The row records the command the runner runs, both built from
    /// `invocation`, so the row and the leaf's record name one command (ARCH 2). The row takes no bundle lock, as the
    /// in-app exports took none. The leaf writes the file and its record, and the app writes no byte after it exits.
    /// A failure fails the row and reaches `onFailure`, which shows today's alert. A cancel reads Cancelled and shows
    /// nothing (UX 4). It is internal so that a row test names the begin site (`cli-parity-gaps` rule 5).
    static func beginTaxTriageExportOperation(
        title: String,
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner,
        reporter: any OperationReporting,
        environmentAdditions: [String: String],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: title,
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
