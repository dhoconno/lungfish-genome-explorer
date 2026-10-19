// TwelveSAmpliconResultViewController+ExportOperationBegin.swift - The Operations row of the 12S result export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

extension TwelveSAmpliconResultViewController {
    /// The leaf's path under `lungfish-cli` (Phase 2.12 lane 12.35, ARCH ruling 1.1 row B3).
    static let resultExportCommandPath = ["fastq", "12s-export"]

    /// The `fastq 12s-export` argv without the executable, for the filters the view froze when the export began.
    ///
    /// The order is the one the leaf records (`FastqTwelveSExportSubcommand.replayArgv`), so the row's command and
    /// the record's argv are one command (ARCH 2). `--force` is set only when the file the save panel returned
    /// exists (ARCH 1.2).
    static func resultExportArguments(
        snapshot: TwelveSAmpliconResultExportSnapshot,
        format: TwelveSAmpliconResultExportFormat,
        outputURL: URL,
        force: Bool
    ) -> [String] {
        let filters = snapshot.filters
        var arguments = resultExportCommandPath + [
            "--bundle", snapshot.bundleURL.path,
            "--export-format", format.cliValue,
            "--output", outputURL.standardizedFileURL.path,
        ]
        if filters.minimumExactReads > 0 {
            arguments += ["--min-exact-reads", String(filters.minimumExactReads)]
        }
        if !filters.normalizedFilterText.isEmpty {
            arguments += ["--filter", filters.normalizedFilterText]
        }
        for group in filters.includedTaxonGroups.sorted() {
            arguments += ["--taxon-group", group]
        }
        for group in filters.excludedTaxonGroups.sorted() {
            arguments += ["--exclude-taxon-group", group]
        }
        if filters.excludeHuman {
            arguments.append("--exclude-human")
        }
        if filters.requireAlternateMatches {
            arguments.append("--require-alternate-matches")
        }
        if filters.minimumUnresolvedReads > 0 {
            arguments += ["--min-unresolved-reads", String(filters.minimumUnresolvedReads)]
        }
        if filters.chimeraFilter != .all {
            arguments += ["--chimera-status", filters.chimeraFilter.rawValue]
        }
        if force {
            arguments.append("--force")
        }
        return arguments
    }

    /// Begins the 12S result export's row for the filters the view froze and runs the leaf on it.
    ///
    /// - Returns: The row's id and the task that runs the leaf, or nil when the row did not start.
    @discardableResult
    static func runResultExport(
        snapshot: TwelveSAmpliconResultExportSnapshot,
        format: TwelveSAmpliconResultExportFormat,
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        beginResultExportOperation(
            arguments: resultExportArguments(
                snapshot: snapshot,
                format: format,
                outputURL: outputURL,
                force: FileManager.default.fileExists(atPath: outputURL.path)
            ),
            outputURL: outputURL.standardizedFileURL,
            runner: runner,
            reporter: reporter,
            environmentAdditions: environmentAdditions,
            onFailure: onFailure
        )
    }

    /// Begins the Operations row of the 12S result export and runs `lungfish-cli fastq 12s-export` for it on the
    /// shared viewer export runner (ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `arguments`. The leaf's contract row is `.text`,
    /// so it runs without `--format json` and the row completes on exit 0 (1.5). The row takes no bundle lock, as the
    /// export before it took none. The leaf writes the report and its record, and the app writes no byte after it
    /// exits. A failure fails the row and reaches `onFailure`, which shows today's alert. A cancel reads Cancelled
    /// and shows nothing (UX 4).
    @discardableResult
    static func beginResultExportOperation(
        arguments: [String],
        outputURL: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let start = reporter.begin(
            title: "Export 12S Results",
            detail: "Writing \(outputURL.lastPathComponent)",
            operationType: .export,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: resultExportCommandPath.joined(separator: " "),
                args: Array(arguments.dropFirst(resultExportCommandPath.count))
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
