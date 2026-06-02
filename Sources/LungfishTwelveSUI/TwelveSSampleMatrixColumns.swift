// TwelveSSampleMatrixColumns.swift — per-sample comparison-matrix column scheme
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Column-identifier scheme and value helpers for the 12S per-sample comparison
/// matrix (samples as columns, species as rows).
///
/// Two dynamic column kinds are appended to the species table, one block per
/// sample:
/// - reads:    `sample::<sampleID>::reads`        → the species' read count in that sample
/// - metadata: `sample::<sampleID>::meta::<field>` → an imported metadata value for that sample
enum TwelveSSampleMatrixColumns {

    enum Parsed: Equatable {
        case reads(sampleID: String)
        case meta(sampleID: String, field: String)
    }

    private static let prefix = "sample"
    private static let separator = "::"

    static func readsColumnID(sampleID: String) -> String {
        [prefix, sampleID, "reads"].joined(separator: separator)
    }

    static func metaColumnID(sampleID: String, field: String) -> String {
        [prefix, sampleID, "meta", field].joined(separator: separator)
    }

    /// Parses a column identifier into its matrix kind, or `nil` for a
    /// non-matrix (fixed) column.
    static func parse(_ id: String) -> Parsed? {
        let parts = id.components(separatedBy: separator)
        guard parts.count >= 3, parts[0] == prefix else { return nil }
        let sampleID = parts[1]
        switch parts[2] {
        case "reads":
            guard parts.count == 3 else { return nil }
            return .reads(sampleID: sampleID)
        case "meta":
            guard parts.count >= 4 else { return nil }
            // Re-join the remainder so fields containing "::" survive.
            let field = parts[3...].joined(separator: separator)
            return .meta(sampleID: sampleID, field: field)
        default:
            return nil
        }
    }

    static func readsValue(_ row: TwelveSScientificNameCountRow, sampleID: String) -> String {
        String(row.count(forSample: sampleID))
    }

    static func metaValue(store: SampleMetadataStore?, sampleID: String, field: String) -> String {
        store?.records[sampleID]?[field] ?? ""
    }
}
