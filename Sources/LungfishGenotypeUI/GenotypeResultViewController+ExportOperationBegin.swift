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

    /// Writes the workbook's capture and request beside the output, then begins its row (Phase 2.12 lane 12.35,
    /// ARCH-12.35-B1 route (a), conditions 2, 3, 6 and 8). The capture is the one the coordinator froze before the
    /// save panel opened. `--force` is set only when the file the save panel returned exists.
    ///
    /// - Returns: The row's id and the task that runs the leaf, or nil when the row did not start.
    @discardableResult
    static func runWorkbookExport(
        snapshot: GenotypeViewportExportSnapshot,
        outputURL: URL,
        pythonURL: URL? = nil,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) async throws -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let python: URL
        if let pythonURL { python = pythonURL }
        else { python = try await CondaManager.shared.toolPath(name: "python", environment: "openpyxl") }
        let invocation = try await GenotypeViewportExportService.writeWorkbookInputs(
            snapshot: snapshot, outputURL: outputURL, pythonURL: python,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
        return beginWorkbookExportOperation(
            invocation: invocation, runner: runner, reporter: reporter,
            environmentAdditions: environmentAdditions, onFailure: onFailure
        )
    }

    /// Begins the Operations row of the workbook export and runs `lungfish-cli genotype export-xlsx --snapshot` for
    /// it on the shared viewer export runner (ARCH ruling 1.5, rules 3 and 4, ARCH-12.35-B1 condition 8).
    ///
    /// The leaf's contract row is `.result(schemaID: "genotype-export-xlsx")`, so it runs without `--format json`
    /// and its row completes on exit 0. The row records the command the runner runs, which `request.json` records
    /// too. The row takes no bundle lock. The leaf writes the workbook and its receipt in one transaction, and the
    /// app writes no byte after it exits. A failure fails the row and reaches `onFailure`. A cancel reads Cancelled.
    @discardableResult
    static func beginWorkbookExportOperation(
        invocation: GenotypeWorkbookExport.Invocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export Genotype Workbook",
            detail: "Writing \(outputURL.lastPathComponent)",
            operationType: .export,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: GenotypeWorkbookExport.commandPath.joined(separator: " "),
                args: Array(arguments.dropFirst(GenotypeWorkbookExport.commandPath.count))
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

    /// The coordinator's export task (ARCH-12.35-B1 condition 8). It runs the workbook's row to its end and throws the
    /// leaf's failure, or `CancellationError` for a cancel, so the coordinator keeps its events and its alert. The
    /// defaulted parameters are the seams the row tests use, so the production default is the code they run.
    static func runWorkbookExportToEnd(
        snapshot: GenotypeViewportExportSnapshot,
        outputURL: URL,
        pythonURL: URL? = nil,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared
    ) async throws {
        guard let begun = try await runWorkbookExport(
            snapshot: snapshot, outputURL: outputURL, pythonURL: pythonURL, runner: runner, reporter: reporter,
            onFailure: { _ in }
        ) else {
            throw CLIViewerExportRunner.Failure(message: "The workbook export did not start.")
        }
        switch await begun.task.value {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        case .failed(let failure):
            throw failure
        }
    }
}
