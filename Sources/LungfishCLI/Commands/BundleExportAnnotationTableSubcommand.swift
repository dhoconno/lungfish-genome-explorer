// BundleExportAnnotationTableSubcommand.swift - lungfish-cli bundle export-annotation-table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Writes the rows of one annotation table tab with its record beside it (Phase 2.12 lane 12.39, ARCH ruling on
/// 12.39 R1 and R3).
///
/// The app's drawer resolves the rows to export and writes their identities, the columns it showed and the region
/// of the coding features it read to the selection file. The leaf reads those rows from the bundle's databases, in
/// the selection's order, and names the selection, the manifest and each file the rows came from as inputs. The
/// app's Export runs this leaf behind its Operations row.
struct BundleExportAnnotationTableSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-annotation-table",
        abstract: "Write one annotation table tab's rows with provenance"
    )

    @Argument(help: "The reference bundle the table's rows come from")
    var bundlePath: String

    @OptionGroup var tab: ViewerExportOptions.Tab<AnnotationTableExport.Tab>
    @OptionGroup var format: ViewerExportOptions.ExportFormat<ScientificTableFormat>
    @OptionGroup var selection: ViewerExportOptions.Selection
    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> ViewerExportInvocation {
        AnnotationTableExport.invocation(
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            tab: tab.tab,
            format: format.format,
            selectionURL: URL(fileURLWithPath: selection.path),
            outputURL: URL(fileURLWithPath: output.path),
            force: output.force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    func run() async throws {
        let command = self
        try await ViewerExportLeaf.run(
            globalOptions: globalOptions,
            startMessage: "Exporting the \(tab.tab.rawValue) table."
        ) { _ in
            try await command.export()
        }
    }

    /// The export, which refuses before it writes and writes payload and record in one transaction.
    func export() async throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let bundleURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
        let selectionURL = URL(fileURLWithPath: invocation.selection ?? "")
        let outputURL = URL(fileURLWithPath: invocation.output)
        let tableFormat = format.format
        guard FileManager.default.fileExists(atPath: selectionURL.path) else {
            throw ViewerExportRefusal("No selection file at \(selectionURL.path). Pass the selection file the app wrote.")
        }
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: [selectionURL, manifestURL], force: invocation.force)
        let selectionFile: ViewerExportSelection
        do {
            selectionFile = try ViewerExportSelection.read(from: selectionURL)
        } catch {
            throw ViewerExportRefusal("The selection file at \(selectionURL.path) cannot be read. \(error.localizedDescription)")
        }
        let rows: AnnotationTableExportRowReader.Rows
        do {
            rows = try await AnnotationTableExportRowReader.read(bundleURL: bundleURL, tab: tab.tab, selection: selectionFile)
        } catch let refusal as AnnotationTableExportRowReader.Refusal {
            throw ViewerExportRefusal(refusal.message)
        }
        let inputURLs = [selectionURL.standardizedFileURL] + rows.inputURLs
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: inputURLs, force: invocation.force)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-export-annotation-table-\(UUID().uuidString).\(tableFormat.rawValue)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let writerReport: ScientificTableWriteReport
        do {
            writerReport = try ScientificTableWriter.writeWithReport(
                rows.snapshot.table, format: tableFormat, to: scratch, shouldCancel: { Task.isCancelled }
            )
        } catch ScientificTableWriterError.cancelled {
            throw CancellationError()
        }

        var explicitOptions: [String: ParameterValue] = [
            "outputPath": .file(outputURL),
            "outputFormat": .string(tableFormat.rawValue),
            "tab": .string(tab.tab.rawValue),
        ]
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: AnnotationTableExport.workflowName,
            sourceURLs: inputURLs,
            outputURL: outputURL,
            outputFormat: AnnotationTableExportSnapshot.provenanceFormat(tableFormat),
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            defaults: AnnotationTableExportSnapshot.recordDefaults,
            resolved: rows.snapshot.recordResolved(writerReport: writerReport),
            runClock: runClock
        )) { stagedURL in
            try FileManager.default.copyItem(at: scratch, to: stagedURL)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        let count = rows.snapshot.table.rows.count
        return ViewerExportLeafOutcome(
            outputURL: outputURL,
            message: "Exported \(count) \(count == 1 ? "row" : "rows") to \(outputURL.lastPathComponent)"
        )
    }
}

extension AnnotationTableExport.Tab: ViewerExportChoice {}
extension ScientificTableFormat: ViewerExportChoice {}
