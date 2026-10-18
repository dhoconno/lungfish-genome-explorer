// ViewerViewController+FASTARecordsExport.swift - The Operations row of the viewers' FASTA records export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Writes the records a viewer holds as one FASTA file beside the export, off the main actor.
private enum FASTARecordsStaging {
    /// Writes `data` as the staged records in `folder` through one `DurableReplace.replace`, so the name holds the
    /// whole file or nothing, on APFS and ExFAT alike (the contract of `StagedSequenceInput`).
    @concurrent
    static func write(_ data: Data, in folder: URL) async throws -> URL {
        _ = try DurableReplace.replace(data, named: FASTARecordsExport.stagedFileName, in: folder)
        return folder.appendingPathComponent(FASTARecordsExport.stagedFileName)
    }
}

extension ViewerViewController {
    /// Begins the Operations row of the FASTA records export and runs `lungfish-cli extract sequence` for it on the
    /// shared viewer export runner (Phase 2.12 lane 12.34, ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-app export took none. The leaf writes the
    /// file and its record, and the app writes no byte after it exits. A failure fails the row and reaches
    /// `onFailure`. A cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from `FASTARecordsExport.invocation`.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginFASTARecordsExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export FASTA",
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

    /// Runs the FASTA records export from the records a viewer holds at the click. It stages the records as one FASTA
    /// file and writes the sequence names to a selection file, both in a new `.lungfish-export-inputs/<UUID>/` folder
    /// beside the output (ARCH ruling 1.3, the durable input contract of `StagedSequenceInput`), then begins the row.
    /// The folder stays after a run that published, since the record names both files. A run that failed, was cancelled
    /// or was refused removes it, since no record names it and the staged records can be large.
    ///
    /// - Parameters:
    ///   - records: The records as the viewer built them. They are joined as given, as the in-app writer joined them.
    ///   - outputURL: The file the user chose. The panel already confirmed a replace, so `--force` is passed only when
    ///     the file exists.
    ///   - onFailure: Shows a failure message, for a run that could not start and for a leaf that failed.
    /// - Returns: The row's id and the task that settles the row, or nil when nothing started.
    @discardableResult
    static func runFASTARecordsExport(
        records: [String],
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let data = Data(records.joined().utf8)
        let document = FASTARecordsExport.document(from: data)
        guard document.preambleLength == 0, !document.records.isEmpty else {
            onFailure("The records hold no FASTA header, so there is nothing to export.")
            return nil
        }
        let selectionURL: URL
        do {
            selectionURL = try FASTARecordsExport.selection(headers: document.records.map(\.header))
                .write(besideOutput: outputURL)
        } catch {
            onFailure(error.localizedDescription)
            return nil
        }
        let folder = selectionURL.deletingLastPathComponent()
        let stagedURL: URL
        do {
            stagedURL = try await FASTARecordsStaging.write(data, in: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            onFailure(error.localizedDescription)
            return nil
        }
        let invocation = FASTARecordsExport.invocation(
            sourceURL: stagedURL,
            selectionURL: selectionURL,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
        guard let begun = beginFASTARecordsExportOperation(
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: { failure in onFailure(failure.message) }
        ) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let settled = Task { @MainActor in
            let outcome = await begun.task.value
            if case .completed = outcome {
                return outcome
            }
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: folder)
            }
            return outcome
        }
        return (begun.operationID, settled)
    }
}
