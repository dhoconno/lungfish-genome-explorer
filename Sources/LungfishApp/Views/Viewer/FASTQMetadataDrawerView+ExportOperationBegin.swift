// FASTQMetadataDrawerView+ExportOperationBegin.swift - The Operations row of the FASTQ metadata drawer's export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

extension FASTQMetadataDrawerView {
    /// Begins the Operations row of the sample sheet export and runs `lungfish-cli fastq export sample-barcodes` for it
    /// on the shared viewer export runner (Phase 2.12 lane 12.34, ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-app export took none. The leaf writes the
    /// file and its record, and the app writes no byte after it exits. A failure fails the row and reaches
    /// `onFailure`. A cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from `FASTQSampleBarcodeExport.invocation`.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginFASTQSampleBarcodeExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let title = invocation.tab == FASTQSampleBarcodeTab.demux.rawValue
            ? "Export Demultiplex Pattern"
            : "Export FASTQ Sample Metadata"
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

    /// Runs the drawer's export from the state frozen at the click. It writes the selection file beside the output,
    /// begins the row and reports through `report` what the old in-app writer reported, `Exported <name>.` when the
    /// leaf wrote the sheet and `Export failed: <message>` when it did not. It touches no drawer state, so the caller
    /// passes the values it froze (ARCH ruling 1.3).
    ///
    /// - Parameters:
    ///   - sourceURL: The FASTQ file or bundle the drawer shows. The leaf checks that it exists and never opens it.
    ///   - tab: The tab the sheet is for.
    ///   - selection: The rows and the demux step's symmetry, from `FASTQSampleBarcodeExport.selection`.
    ///   - outputURL: The file the user chose. The panel already confirmed a replace, so `--force` is passed only when
    ///     the file exists.
    ///   - report: Shows a message on the drawer's status line.
    /// - Returns: The row's id and the task that settles the row and reports, or nil when nothing started.
    @discardableResult
    func runSampleBarcodeExport(
        sourceURL: URL?,
        tab: FASTQSampleBarcodeTab,
        selection: ViewerExportSelection,
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        report: @escaping @MainActor @Sendable (String) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.standardizedFileURL.path) else {
            report("Export failed: Cannot export FASTQ metadata because no durable source FASTQ or bundle is available for provenance.")
            return nil
        }
        let selectionURL: URL
        do {
            selectionURL = try selection.write(besideOutput: outputURL)
        } catch {
            report("Export failed: \(error.localizedDescription)")
            return nil
        }
        let invocation = FASTQSampleBarcodeExport.invocation(
            bundleURL: sourceURL,
            tab: tab,
            selectionURL: selectionURL,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
        guard let begun = Self.beginFASTQSampleBarcodeExportOperation(
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: { failure in report("Export failed: \(failure.message)") }
        ) else { return nil }
        let name = outputURL.lastPathComponent
        let settled = Task { @MainActor in
            let outcome = await begun.task.value
            if case .completed = outcome {
                report("Exported \(name).")
            }
            return outcome
        }
        return (begun.operationID, settled)
    }
}
