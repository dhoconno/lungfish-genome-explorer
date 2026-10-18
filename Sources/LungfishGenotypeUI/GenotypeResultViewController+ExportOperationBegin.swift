// GenotypeResultViewController+ExportOperationBegin.swift - The Operations row of the manual definitions export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension GenotypeResultViewController {
    /// Writes the store's assignments to the selection file beside the output, then begins the export's row (Phase
    /// 2.12 lane 12.35, ARCH ruling 1.3 and 1.5). `--force` is set only when the file the save panel returned exists.
    ///
    /// - Returns: The row's id and the task that runs the leaf, or nil when the row did not start.
    @discardableResult
    static func runManualDefinitionsExport(
        assignments: [ManualHaplotypeAssignment],
        bundleURL: URL,
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) throws -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let force = FileManager.default.fileExists(atPath: outputURL.path)
        let selectionURL = try GenotypeManualDefinitionsExport.selection(assignments: assignments)
            .write(besideOutput: outputURL)
        return beginManualDefinitionsExportOperation(
            invocation: GenotypeManualDefinitionsExport.invocation(
                bundleURL: bundleURL,
                selectionURL: selectionURL,
                outputURL: outputURL,
                force: force
            ),
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: onFailure
        )
    }

    /// Begins the Operations row of the manual definitions export and runs `lungfish-cli genotype
    /// export-manual-definitions` for it on the shared viewer export runner (ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-app export took none. The leaf writes the
    /// file and its record, and the app writes no byte after it exits. A failure fails the row and reaches
    /// `onFailure`, which shows today's alert. A cancel reads Cancelled and shows nothing (UX 4).
    @discardableResult
    static func beginManualDefinitionsExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export Manual Haplotype Definitions",
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
