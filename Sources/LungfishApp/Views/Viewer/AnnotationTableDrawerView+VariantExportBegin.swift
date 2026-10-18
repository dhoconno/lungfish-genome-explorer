// AnnotationTableDrawerView+VariantExportBegin.swift - The Operations rows of the bookmarked variants and sample template exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow

extension AnnotationTableDrawerView {
    // MARK: - What the drawer passes to the leaves

    /// The variant databases the bookmarked variants export reads, one path for each of the drawer's variant tracks
    /// in its track order, or nil when no track holds a bookmark, which the drawer says before its save panel.
    ///
    /// The paths are not deduplicated, so two tracks over one database repeat its bookmarks as the drawer's loop did
    /// before the leaf (Phase 2.12 lane 12.39, B6).
    func bookmarkedVariantsExportDatabaseURLs() -> [URL]? {
        guard let index = searchIndex else { return nil }
        let handles = index.variantDatabaseHandles
        guard handles.contains(where: { !$0.db.bookmarkedVariants().isEmpty }) else { return nil }
        return handles.map { $0.db.databaseURL }
    }

    /// The sample template leaf's invocation for the bundle that holds the drawer's variant databases, with the
    /// drawer's sample metadata columns and the format the save panel's name asks for (lane 12.39, B11).
    func variantSampleTemplateExportInvocation(bundleURL: URL, outputURL: URL) -> ViewerExportInvocation {
        VariantSampleTemplateExport.invocation(
            bundleURL: bundleURL,
            metadataColumns: sampleMetadataFields,
            format: VariantSampleTemplateExport.format(forOutput: outputURL),
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    // MARK: - The rows

    /// Begins the Operations row of the bookmarked variants export and runs `lungfish-cli variants export bookmarked`
    /// for it on the shared viewer export runner (Phase 2.12 lane 12.39, ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command. The row takes no bundle lock, as the in-app export took none. The leaf writes the file and
    /// its record, and the app writes no byte after it exits. A failure fails the row and reaches `onFailure`, which
    /// shows the drawer's "Bookmark Export Failed" alert. A cancel reads Cancelled and shows nothing.
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from `BookmarkedVariantExport.invocation`.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginBookmarkedVariantsExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export Bookmarked Variants",
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

    /// Begins the Operations row of the sample metadata template export and runs
    /// `lungfish-cli variants export sample-template` for it on the shared viewer export runner (lane 12.39, ARCH
    /// ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, takes no bundle lock and writes no byte itself. The template
    /// before the leaf wrote no record and only logged a failure. Now the leaf writes the record, and a failure fails
    /// the row and reaches `onFailure`, which shows an alert. A cancel reads Cancelled and shows nothing.
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from `variantSampleTemplateExportInvocation(bundleURL:outputURL:)`.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginVariantSampleTemplateExportOperation(
        invocation: ViewerExportInvocation,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export Sample Metadata Template",
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

    /// The alert a failed variant drawer export shows on the drawer's window, with the leaf's own words.
    static func presentVariantExportFailure(title: String, message: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
