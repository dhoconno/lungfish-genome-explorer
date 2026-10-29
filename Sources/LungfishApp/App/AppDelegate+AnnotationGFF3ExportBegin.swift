// AppDelegate+AnnotationGFF3ExportBegin.swift - The Operations row of the GFF3 annotation export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishOperations
import LungfishWorkflow

/// The GFF3 export runs `lungfish-cli bundle export-gff3` behind an Operations row (Phase 2.12 lane 12.39, ARCH
/// ruling on 12.39 R2). It lives here because AppDelegate+ImportCenter.swift is at its size baseline.
extension AppDelegate {
    /// Begins the Operations row of the GFF3 export and runs `lungfish-cli bundle export-gff3` for it on the shared
    /// viewer export runner (ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command (ARCH 2). The row takes no bundle lock, as the in-app export took none. The leaf writes the
    /// file and its record, and the app writes no byte after it exits. A failure fails the row and reaches
    /// `onFailure`. A cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from `AnnotationGFF3Export.invocation(bundleURL:...)` or
    ///     `invocation(selectionURL:...)`.
    ///   - sourceName: The source's name, which the row's detail shows.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginAnnotationGFF3ExportOperation(
        invocation: AnnotationGFF3Export.Invocation,
        sourceName: String,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let commandPath = AnnotationGFF3Export.commandPath
        let outputURL = URL(fileURLWithPath: invocation.output)
        let start = reporter.begin(
            title: "Export Annotations as GFF3",
            detail: "Writing \(outputURL.lastPathComponent) from \(sourceName)",
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
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }

    /// The invocation for one source. A sidebar bundle takes the bundle form, and an open document writes its
    /// annotations, frozen at the click, to a selection file beside the output before the row begins (ARCH ruling
    /// 1.3). The save panel already confirmed a replace, so the leaf may overwrite.
    nonisolated static func annotationGFF3ExportInvocation(
        annotations: [SequenceAnnotation],
        source: AnnotationExportService.Source,
        outputURL: URL
    ) throws -> AnnotationGFF3Export.Invocation {
        if source.kind == .sidebarBundle, let bundleURL = source.urls.first {
            return AnnotationGFF3Export.invocation(bundleURL: bundleURL, outputURL: outputURL, force: true)
        }
        let selectionURL = try ViewerExportSelection(documentAnnotations: AnnotationExportDocumentSelection(
            sourceName: source.name,
            sourcePath: source.urls.first?.path,
            annotations: annotations
        )).write(besideOutput: outputURL)
        return AnnotationGFF3Export.invocation(selectionURL: selectionURL, outputURL: outputURL, force: true)
    }

    /// The panel's OK. Begins the row and reports the end. The completion words, "Export complete", go through
    /// `report`. A failure goes through `reportFailure` as a `FailureReport` that names the step and the next
    /// thing to try, with the error only in its details (ALERT-PRESENTER, Phase 3.1).
    func startAnnotationGFF3Export(
        annotations: [SequenceAnnotation],
        source: AnnotationExportService.Source,
        outputURL: URL,
        report: @escaping @MainActor @Sendable (String, String) -> Void,
        reportFailure: @escaping @MainActor @Sendable (FailureReport) -> Void
    ) {
        let invocation: AnnotationGFF3Export.Invocation
        do {
            invocation = try Self.annotationGFF3ExportInvocation(annotations: annotations, source: source, outputURL: outputURL)
        } catch {
            reportFailure(AppFailureReports.prepareAnnotationExport(error))
            return
        }
        guard let begun = Self.beginAnnotationGFF3ExportOperation(
            invocation: invocation,
            sourceName: source.name,
            onFailure: { failure in reportFailure(AppFailureReports.exportAnnotations(failure)) }
        ) else { return }
        let count = annotations.count
        Task { @MainActor in
            if case .completed = await begun.task.value {
                report("Export complete", "Exported \(count) annotations from \(source.name) to \(outputURL.lastPathComponent).")
            }
        }
    }
}
