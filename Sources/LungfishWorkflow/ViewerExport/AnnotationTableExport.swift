// AnnotationTableExport.swift - The annotation table export, shared by the app and its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The annotation table export of the drawer's four tabs (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 and R3).
///
/// The drawer resolves the exported rows before `begin` and writes their identities, the columns as shown and the
/// region of the coding features it read to a selection file beside the output. `bundle export-annotation-table`
/// reads those rows by identity from the bundle's databases, rebuilds the table with the drawer's builder
/// (``AnnotationTableExportSnapshot``) and writes it with its record.
public enum AnnotationTableExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling X-1, a sibling of `bundle export`).
    public static let commandPath = ["bundle", "export-annotation-table"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish bundle export-annotation-table"

    /// The drawer's tables, the value of `--tab`, spelled as the base's `--tab` spelled them.
    public enum Tab: String, CaseIterable, Codable, Sendable {
        case annotations
        case variants
        case genotypes
        case samples
    }

    /// The ids of the derived variant columns and the caller settings column, which no database stores.
    package static let callerSettingsColumnID = "CallerSettingsColumn"
    package static let codingFeatureColumnID = "CodingFeatureColumn"
    package static let consequenceColumnID = "ConsequenceColumn"
    package static let aaChangeColumnID = "AAChangeColumn"

    /// The leaf's invocation for one export, with absolute standardized paths.
    public static func invocation(
        bundleURL: URL,
        tab: Tab,
        format: ScientificTableFormat,
        selectionURL: URL,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            tab: tab.rawValue,
            outputFormat: format.rawValue,
            selection: selectionURL.standardizedFileURL.path,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The text of the caller settings and derived variant columns of `rows`, keyed by row identity and then by
    /// column id, as the drawer and the leaf write them. Other columns get no text here.
    package static func variantResolvedText(
        rows: [AnnotationSearchResult],
        columns: [ScientificTableColumn],
        callerSettingsByTrack: [String: String],
        resolverSnapshot: VariantTableExportResolverSnapshot
    ) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: rows.map { row in
            let resolved = resolverSnapshot.resolve(row)
            let identity = "\(row.trackId):\(row.variantRowId.map(String.init) ?? row.id.uuidString)"
            let values = Dictionary(uniqueKeysWithValues: columns.map { column -> (String, String) in
                let value: String
                switch column.id {
                case callerSettingsColumnID:
                    value = callerSettingsByTrack[row.trackId] ?? "Not recorded"
                case codingFeatureColumnID:
                    value = resolved.codingFeature
                case consequenceColumnID:
                    value = resolved.consequence
                case aaChangeColumnID:
                    value = resolved.aaChange
                default: value = ""
                }
                return (column.id, value)
            })
            return (identity, values)
        })
    }
}
