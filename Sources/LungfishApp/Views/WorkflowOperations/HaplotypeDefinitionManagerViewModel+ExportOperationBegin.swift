// HaplotypeDefinitionManagerViewModel+ExportOperationBegin.swift - The Operations row of the definition export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension HaplotypeDefinitionManagerViewModel {
    /// The `haplotypes export` argv without the executable for the definition the manager selected.
    ///
    /// It names every option the export uses (Phase 2.12 lane 12.35 row B7, `docs/contracts/CLI-EQUIVALENCE.md`).
    /// The project the window lists from, the assay id and the scope pick the record, as the in-app export picked it.
    static func definitionExportArguments(
        record: HaplotypeDefinitionRecord,
        projectURL: URL?,
        outputURL: URL
    ) -> [String] {
        HaplotypeDefinitionExport.arguments(
            definitionID: record.definitionSet.id,
            outputPath: outputURL.standardizedFileURL.path,
            projectPath: projectURL?.standardizedFileURL.path,
            assayID: record.definitionSet.assayID,
            scope: record.scope.rawValue
        )
    }

    /// Begins the definition export's row for the selected record and runs the leaf on it.
    ///
    /// - Returns: The row's id and the task that runs the leaf, or nil when the row did not start.
    @discardableResult
    static func runDefinitionExport(
        record: HaplotypeDefinitionRecord,
        projectURL: URL?,
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        beginDefinitionExportOperation(
            arguments: definitionExportArguments(record: record, projectURL: projectURL, outputURL: outputURL),
            outputURL: outputURL.standardizedFileURL,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: onFailure
        )
    }

    /// Begins the Operations row of the definition export and runs `lungfish-cli haplotypes export` for it on the
    /// shared viewer export runner (ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `arguments`. The leaf's contract row is
    /// `.result`, so it runs without `--format json` and the row completes on exit 0 (1.5). The row takes no lock,
    /// as the in-app export took none. The leaf writes the file and its record, and the app writes no byte after it
    /// exits. A failure fails the row and reaches `onFailure`, which shows it in the window. A cancel reads Cancelled
    /// and shows nothing (UX 4).
    @discardableResult
    static func beginDefinitionExportOperation(
        arguments: [String],
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let commandPath = HaplotypeDefinitionExport.commandPath
        let start = reporter.begin(
            title: "Export Haplotype Definition",
            detail: "Writing \(outputURL.lastPathComponent)",
            operationType: .export,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: commandPath.joined(separator: " "),
                args: Array(arguments.dropFirst(commandPath.count))
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
                emitsEvents: false,
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }
}
