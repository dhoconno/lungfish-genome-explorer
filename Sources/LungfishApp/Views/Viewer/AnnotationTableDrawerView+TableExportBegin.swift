// AnnotationTableDrawerView+TableExportBegin.swift - The Operations row of the annotation table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow

/// A row the export cannot name, one with no database row id (ARCH ruling on 12.39 R1 item 7).
struct AnnotationTableExportRowNotStored: LocalizedError, Equatable {
    var errorDescription: String? {
        "This row is not stored in an annotation database, so it cannot be exported."
    }
}

/// The leaf's failure, which the drawer shows under "Could not export the table", with the leaf's words behind Show Details.
struct AnnotationTableExportLeafFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The annotation table export runs `lungfish-cli bundle export-annotation-table` behind an Operations row (Phase
/// 2.12 lane 12.39, ARCH ruling on 12.39 R1). The drawer resolves the rows under its progress sheet, writes their
/// identities and the state frozen at the click to a selection file beside the output, then begins the row. It
/// lives here because the drawer's main files are at their size baselines.
extension AnnotationTableDrawerView {
    /// The panel's capture, with the state the selection file carries frozen at the click (R1 items 2 to 4). The
    /// columns are the ones shown. Numeric and integer ids are the variant tab's INFO columns, the genotype tab's
    /// `gt` ones, or none. A written derived variant column names every annotation track of the bundle with a
    /// database in `bundleCodingFeatureTrackIDs`, an empty list when the viewer shows no bundle, so the leaf reads the
    /// CDS over the exported rows and names the genome (lane 13.38, V1-1). The sample tab writes the
    /// visible flag and display name of every exported row.
    func captureAnnotationTableExport(scope: AnnotationTableExportScope) throws -> AnnotationTablePendingExport {
        var pending = try captureScientificTableExport(scope: scope)
        let columns = tableView.tableColumns.map {
            ScientificTableColumn(id: $0.identifier.rawValue, title: $0.title)
        }
        let infoIDs = exportNumericInfoColumnIDs()
        let typed: (numeric: Set<String>, integer: Set<String>)
        switch pending.tab {
        case "variants": typed = infoIDs
        case "genotypes": typed = (Set(infoIDs.numeric.map { "gt\($0)" }), Set(infoIDs.integer.map { "gt\($0)" }))
        default: typed = ([], [])
        }
        let derivedColumnIDs = [Self.codingFeatureColumn, Self.consequenceColumn, Self.aaChangeColumn].map(\.rawValue)
        // V1-1 item 2. A written derived column names every annotation track of the bundle that has a database, the
        // tracks the drawer's read and the leaf's read both take, and no region (lane 13.38).
        var bundleTrackIDs: [String]?
        if pending.tab == "variants", columns.contains(where: { derivedColumnIDs.contains($0.id) }) {
            bundleTrackIDs = (delegate?.annotationDrawerVariantExportResolverSnapshot(self) ?? .empty).referenceBundle
                .map { VariantTableBundleCodingFeatures.trackIDs(bundle: $0) } ?? []
        }
        pending.tableSelection = AnnotationTableExportSelection(
            scope: scope.rawValue, columns: columns,
            numericColumnIDs: Array(typed.numeric), integerColumnIDs: Array(typed.integer),
            variantChromosomeAliases: variantChromosomeAliasMap, bundleCodingFeatureTrackIDs: bundleTrackIDs
        )
        pending.bundleURL = try delegate?.annotationDrawerAdditionalExportSources(self)
            .first { $0.lastPathComponent == BundleManifest.filename }?
            .deletingLastPathComponent()
        if pending.tab == "samples" {
            let rows = scope == .selected
                ? tableView.selectedRowIndexes.compactMap { displayedSamples.indices.contains($0) ? displayedSamples[$0] : nil }
                : displayedSamples
            pending.editedValues = Self.sampleEditedValues(rows)
        }
        return pending
    }

    /// The variant tab's numeric and integer INFO column ids, as the export types its cells.
    func exportNumericInfoColumnIDs() -> (numeric: Set<String>, integer: Set<String>) {
        let numeric = Set(infoColumnKeys.compactMap { info -> String? in
            let type = info.type.lowercased()
            return (type.contains("float") || type.contains("number") || type.contains("real"))
                ? "info_\(info.key)" : nil
        })
        let integer = Set(infoColumnKeys.compactMap { info -> String? in
            info.type.lowercased().contains("integer") ? "info_\(info.key)" : nil
        })
        return (numeric, integer)
    }

    /// The sample tab's `visible` (`true` or `false`) and `displayName` for each exported row (R1 item 3).
    nonisolated static func sampleEditedValues(_ rows: [SampleDisplayRow]) -> [String: [String: String]] {
        var values: [String: [String: String]] = [:]
        for row in rows where values[row.rowKey] == nil {
            var edits = ["visible": row.isVisible ? "true" : "false"]
            if let displayName = row.displayName { edits["displayName"] = displayName }
            values[row.rowKey] = edits
        }
        return values
    }

    /// The leaf's invocation for the collected rows. It refuses an annotation or variant row with no database row id
    /// before writing anything (R1 item 7), then writes the selection file into a new inputs folder beside the
    /// output with the rows' identities in order and the query the snapshot describes. The save panel already
    /// confirmed a replace, so the leaf may overwrite.
    nonisolated static func annotationTableExportInvocation(
        snapshot: AnnotationTableExportSnapshot,
        bundleURL: URL?,
        tableSelection: AnnotationTableExportSelection,
        editedValues: [String: [String: String]],
        format: ScientificTableFormat,
        outputURL: URL
    ) throws -> ViewerExportInvocation {
        guard let bundleURL, let tab = AnnotationTableExport.Tab(rawValue: snapshot.tab) else {
            throw AnnotationTableExportServiceError.noScientificSources
        }
        if tab == .annotations || tab == .variants, snapshot.rowIdentities.contains(where: { identity in
            guard let colon = identity.lastIndex(of: ":") else { return true }
            return Int64(identity[identity.index(after: colon)...]) == nil
        }) {
            throw AnnotationTableExportRowNotStored()
        }
        var table = tableSelection
        table.scope = snapshot.scope.rawValue
        table.query = snapshot.queryDescription
        let selectionURL = try ViewerExportSelection(
            identities: snapshot.rowIdentities, editedValues: editedValues, annotationTable: table
        ).write(besideOutput: outputURL)
        return AnnotationTableExport.invocation(
            bundleURL: bundleURL, tab: tab, format: format,
            selectionURL: selectionURL, outputURL: outputURL, force: true
        )
    }

    /// Begins the Operations row of the table export and runs the leaf for it on the shared viewer export runner
    /// (ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command. The row takes no bundle lock, as the in-app export took none. The leaf writes the file and
    /// its record, and the app writes no byte after it exits. A failure fails the row and reaches `onFailure`. A
    /// cancel reads Cancelled and shows nothing (UX 4).
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from `annotationTableExportInvocation(...)`.
    ///   - rowCount: The count of rows the selection names, which the row's detail shows.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not
    ///   start.
    @discardableResult
    static func beginAnnotationTableExportOperation(
        invocation: ViewerExportInvocation,
        rowCount: Int,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let commandPath = AnnotationTableExport.commandPath
        let outputURL = URL(fileURLWithPath: invocation.output)
        let tab = invocation.tab ?? "table"
        let rows = rowCount == 1 ? "1 row" : "\(rowCount) rows"
        let start = reporter.begin(
            title: "Export \(tab.capitalized) Table",
            detail: "Writing \(rows) to \(outputURL.lastPathComponent)",
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
                completionDetail: "Exported \(rows) to \(outputURL.lastPathComponent)",
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }
}
