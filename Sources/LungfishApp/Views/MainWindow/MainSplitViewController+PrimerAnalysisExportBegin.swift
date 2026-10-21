// MainSplitViewController+PrimerAnalysisExportBegin.swift - The Operations rows of the two primer exports that run the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension MainSplitViewController {
    /// Begins the Operations row of a primer order export and runs `lungfish-cli primers analysis export-order` for it
    /// on the shared viewer export runner (Phase 2.13 lane 13.43 M3, ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`
    /// (``primerOrderExportInvocation(draft:metadata:destinationURL:)``), so the row, the leaf's record and the command
    /// Copy CLI Command puts on the pasteboard are one command. The row locks the new folder, `invocation.output`, as the
    /// in-process export did. The leaf writes the order and its record in one transaction and the app writes no byte
    /// after it exits. A failure fails the row and shows no alert, as before, and a cancel reads Cancelled.
    ///
    /// - Parameters:
    ///   - title: The row's title, which names the scope of the order.
    ///   - detail: The row's first detail.
    ///   - invocation: The leaf's invocation from ``primerOrderExportInvocation(draft:metadata:destinationURL:)``.
    ///   - routeContext: The project and window the row belongs to.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onCompleted: Called on the main actor once the leaf has written the order, so the sidebar shows the folder.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row was refused.
    @discardableResult
    static func beginPrimerOrderExportOperation(
        title: String,
        detail: String,
        invocation: ViewerExportInvocation,
        routeContext: OperationRouteContext,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onCompleted: @escaping @MainActor @Sendable () -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let start = reporter.begin(
            title: title,
            detail: detail,
            operationType: .workflow,
            targetBundleURL: URL(fileURLWithPath: invocation.output, isDirectory: true),
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: invocation.commandPath.joined(separator: " "),
                args: Array(invocation.arguments().dropFirst(invocation.commandPath.count))
            ),
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        )
        guard case .started(let operationID) = start else { return nil }
        return (operationID, runPrimerExportLeaf(
            operationID: operationID, invocation: invocation, runner: runner,
            environmentAdditions: environmentAdditions, onCompleted: onCompleted
        ))
    }

    /// Begins the Operations row of "Save Primer FASTA Bundle" or "Extract Reference Amplicon" and runs
    /// `lungfish-cli primers analysis export-selection` for it on the shared viewer export runner (Phase 2.13 lane 13.43
    /// M3). The row, the record and the runner share `invocation`
    /// (``primerSelectionExportInvocation(analysisURL:selection:kind:destinationURL:)``), the row locks the new export
    /// folder, and `onCompleted` runs on the main actor once the leaf has written the folder.
    ///
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row was refused.
    @discardableResult
    static func beginPrimerAnalysisSelectionExportOperation(
        title: String,
        invocation: ViewerExportInvocation,
        routeContext: OperationRouteContext,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onCompleted: @escaping @MainActor @Sendable () -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let start = reporter.begin(
            title: title,
            detail: "Verifying saved primer analysis…",
            operationType: .workflow,
            targetBundleURL: URL(fileURLWithPath: invocation.output, isDirectory: true),
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: invocation.commandPath.joined(separator: " "),
                args: Array(invocation.arguments().dropFirst(invocation.commandPath.count))
            ),
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        )
        guard case .started(let operationID) = start else { return nil }
        return (operationID, runPrimerExportLeaf(
            operationID: operationID, invocation: invocation, runner: runner,
            environmentAdditions: environmentAdditions, onCompleted: onCompleted
        ))
    }

    /// Runs the leaf for a row that began and settles the row. The row reads Completed with the new folder and
    /// "Saved in the project's Analyses folder.", which the in-process commit wrote before this lane.
    private static func runPrimerExportLeaf(
        operationID: UUID,
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner,
        environmentAdditions: [String: String],
        onCompleted: @escaping @MainActor @Sendable () -> Void
    ) -> Task<CLIViewerExportRunner.Outcome, Never> {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output, isDirectory: true)
        return Task { @MainActor in
            let outcome = await runner.run(
                arguments: arguments,
                outputURL: outputURL,
                operationID: operationID,
                completionDetail: "Saved in the project's Analyses folder.",
                environmentAdditions: environmentAdditions
            )
            if case .completed = outcome {
                onCompleted()
            }
            return outcome
        }
    }
}
