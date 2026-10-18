// SequenceViewerView+FASTAExport.swift - The Operations row of the sequence view's FASTA export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension SequenceViewerView {
    /// Runs the sequence view's FASTA export for the sequence the view held at the click (Phase 2.12 lane 12.34, ARCH
    /// ruling 1.1 row A12). It stages the sequence as a one-record FASTA file in a new
    /// `.lungfish-export-inputs/<UUID>/` folder beside the output (the durable input contract of `StagedSequenceInput`,
    /// ARCH ruling 1.3), then begins the row that runs
    /// `lungfish-cli extract sequence <sequence.fa> --sequence=<name> --line-width 80 -o <file>` on the shared viewer
    /// export runner. The staged text holds the name, the description and the bases on one line, and the leaf wraps the
    /// bases at the width the command names. The folder stays after a run that published, since the record names the
    /// staged file. A run that failed, was cancelled or was refused removes it when it left no output.
    ///
    /// The row is the one the FASTA records export begins, since both run the same leaf and write one FASTA file.
    ///
    /// - Parameters:
    ///   - name: The sequence's name.
    ///   - description: The sequence's description, if it has one.
    ///   - bases: The sequence's bases as the view shows them.
    ///   - outputURL: The file the user chose. The panel already confirmed a replace, so `--force` is passed only when
    ///     the file exists.
    ///   - onFailure: Shows a failure message, for a run that could not start and for a leaf that failed.
    /// - Returns: The row's id and the task that settles the row, or nil when nothing started.
    @discardableResult
    static func runSequenceFASTAExport(
        name: String,
        description: String?,
        bases: String,
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let data = Data(FASTARecordsExport.sequenceText(name: name, description: description, bases: bases).utf8)
        let folder: URL
        do {
            folder = try FASTARecordsExport.makeInputsFolder(besideOutput: outputURL)
        } catch {
            onFailure(error.localizedDescription)
            return nil
        }
        let stagedURL: URL
        do {
            stagedURL = try await FASTARecordsStaging.write(
                data, named: FASTARecordsExport.stagedSequenceFileName, in: folder
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            onFailure(error.localizedDescription)
            return nil
        }
        let invocation = FASTARecordsExport.invocation(
            sourceURL: stagedURL,
            sequences: [FASTARecordsExport.sequenceIdentity(name: name, description: description)],
            lineWidth: FASTARecordsExport.sequenceViewLineWidth,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
        guard let begun = ViewerViewController.beginFASTARecordsExportOperation(
            invocation: invocation,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: { failure in onFailure(failure.message) }
        ) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return ViewerViewController.settleStagedExport(begun, outputURL: outputURL, folder: folder)
    }
}
