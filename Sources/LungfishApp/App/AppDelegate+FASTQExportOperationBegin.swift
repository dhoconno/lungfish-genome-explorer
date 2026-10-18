// AppDelegate+FASTQExportOperationBegin.swift - The Operations rows of the sidebar's FASTQ bundle export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

extension AppDelegate {
    /// One bundle of the sidebar's Export as FASTQ, with the file the user chose for it.
    struct FASTQBundleExport: Sendable, Equatable {
        let bundleURL: URL
        let outputURL: URL
        let isDerived: Bool
        /// The sidebar item's title, which the summary alert names.
        let title: String
    }

    /// How one bundle's export ended.
    struct FASTQBundleExportResult: Sendable, Equatable {
        enum End: Sendable, Equatable {
            case completed
            case cancelled
            case failed(String)
        }

        let export: FASTQBundleExport
        /// The row's id, or nil when no row began.
        let operationID: UUID?
        let end: End
    }

    /// What the alert after a batch says. The words are the ones the in-app writer showed, with the leaf's message
    /// where the writer's error was.
    struct FASTQExportSummary: Equatable {
        enum Style: Equatable {
            case informational
            case warning
            case critical
        }

        let title: String
        let message: String
        let style: Style
        /// The one file a single successful export offers to reveal in Finder.
        let revealURL: URL?
    }

    /// Begins the Operations row of one bundle's export and runs `lungfish-cli fastq export reads` for it on the
    /// shared viewer export runner (Phase 2.12 lane 12.38, ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-app export took none. The leaf writes the
    /// file and its record, and the app writes no byte after it exits. A failure fails the row and reaches
    /// `onFailure`. A cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not start.
    @discardableResult
    static func beginFASTQBundleExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export FASTQ",
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

    /// Runs the exports of a selection one after another, one row and one leaf run each, as the in-app writer ran
    /// them in one detached task. `--force` is passed only for a file that exists, which the save panel confirmed for
    /// a single export and which the batch folder's own names overwrote before. A cancel stops the batch.
    @MainActor
    static func runFASTQBundleExports(
        _ exports: [FASTQBundleExport],
        runner makeRunner: @MainActor () -> CLIViewerExportRunner = { CLIViewerExportRunner() },
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:]
    ) async -> [FASTQBundleExportResult] {
        var results: [FASTQBundleExportResult] = []
        for export in exports {
            let invocation = FASTQReadsExport.invocation(
                bundleURL: export.bundleURL,
                outputURL: export.outputURL,
                isDerived: export.isDerived,
                force: FileManager.default.fileExists(atPath: export.outputURL.path)
            )
            guard let begun = beginFASTQBundleExportOperation(
                invocation: invocation,
                runner: makeRunner(),
                reporter: reporter,
                environmentAdditions: environmentAdditions,
                onFailure: { _ in }
            ) else {
                results.append(FASTQBundleExportResult(export: export, operationID: nil, end: .failed("The export could not start.")))
                continue
            }
            switch await begun.task.value {
            case .completed:
                results.append(FASTQBundleExportResult(export: export, operationID: begun.operationID, end: .completed))
            case .cancelled:
                results.append(FASTQBundleExportResult(export: export, operationID: begun.operationID, end: .cancelled))
                return results
            case .failed(let failure):
                results.append(FASTQBundleExportResult(export: export, operationID: begun.operationID, end: .failed(failure.message)))
            }
        }
        return results
    }

    /// The alert after a batch, or nil after a cancel, which reads Cancelled in the Operations panel and shows nothing.
    static func fastqExportSummary(for results: [FASTQBundleExportResult]) -> FASTQExportSummary? {
        if results.contains(where: { $0.end == .cancelled }) { return nil }
        let failed: [(title: String, error: String)] = results.compactMap {
            if case .failed(let message) = $0.end { return ($0.export.title, message) }
            return nil
        }
        let succeeded = results.count - failed.count
        let failureLines = failed.map { "\($0.title): \($0.error)" }.joined(separator: "\n")
        if failed.isEmpty {
            let message = results.count == 1
                ? "\(results[0].export.title) exported as \(results[0].export.outputURL.lastPathComponent)."
                : "Successfully exported \(succeeded) FASTQ file(s)."
            return FASTQExportSummary(
                title: "Export Complete", message: message, style: .informational,
                revealURL: results.count == 1 ? results[0].export.outputURL : nil
            )
        }
        if succeeded == 0 {
            return FASTQExportSummary(title: "Export Failed", message: failureLines, style: .critical, revealURL: nil)
        }
        return FASTQExportSummary(
            title: "Export Partially Complete",
            message: "\(succeeded) succeeded, \(failed.count) failed.\n\n" + failureLines,
            style: .warning, revealURL: nil
        )
    }
}
