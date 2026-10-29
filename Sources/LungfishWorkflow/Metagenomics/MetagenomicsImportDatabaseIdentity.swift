// MetagenomicsImportDatabaseIdentity.swift - What an imported classifier result says about its database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The facts an import record holds about the database behind the result it imports (DB-IDENTITY, Phase 3.1,
/// BIO-DB-IDENTITY section 3, Imports).
///
/// An import ran no classifier, so it has no database to cite and no checksum. A result that names no database gets the
/// status ``DatabaseIdentityStatus/notNamedBySource`` and a note that says so, so a methods section knows to cite the run
/// that made the result. A key the source does not state is left out, never set to `unknown`.
enum MetagenomicsImportDatabaseIdentity {
    /// The status and the note of an import whose result names no database. `tool` is the name a person reads.
    static func notNamedBySource(tool: String) -> [String: ParameterValue] {
        [
            "databaseIdentityStatus": .string(DatabaseIdentityStatus.notNamedBySource.rawValue),
            "databaseIdentityNote": .string(
                "The \(tool) result names no database, so this record cannot name the release that made its calls. "
                    + "Cite it from the run that made the result."
            ),
        ]
    }

    /// `resolved`, an import's resolved defaults, with the status and the note of a result that names no database
    /// added. A key the import already holds stays.
    static func notNamedBySource(tool: String, adding resolved: [String: ParameterValue]) -> [String: ParameterValue] {
        resolved.merging(notNamedBySource(tool: tool)) { current, _ in current }
    }

    /// `resolved`, an NVD import's resolved defaults, with the BLAST and STAT database versions its rows state, `versions`
    /// holding the (BLAST, STAT) pair of each row. A version
    /// is one string when every row agrees and the sorted array of the distinct values when rows differ, so a mixed import
    /// never reads as one release, and a key is left out when no row states one. The status is `namedBySource` with a note
    /// that no checksum is stated. A result whose rows state neither version names no database.
    static func nvd(
        versions: [(String, String)],
        adding resolved: [String: ParameterValue]
    ) -> [String: ParameterValue] {
        var stated: [String: ParameterValue] = [:]
        if let blast = versionValue(of: versions.map { $0.0 }) {
            stated["blastDatabaseVersion"] = blast
        }
        if let stat = versionValue(of: versions.map { $0.1 }) {
            stated["statDatabaseVersion"] = stat
        }
        guard !stated.isEmpty else {
            return notNamedBySource(tool: "NVD", adding: resolved)
        }
        stated["databaseIdentityStatus"] = .string(DatabaseIdentityStatus.namedBySource.rawValue)
        stated["databaseIdentityNote"] = .string("The NVD result states its BLAST and STAT database versions and no checksum.")
        return resolved.merging(stated) { current, _ in current }
    }

    /// `resolved`, a CZ-ID import's resolved defaults, with the status and the note. The versions stay under the three
    /// keys CZ-ID released. The status is `namedBySource` when the report names an NT or an NR version, and a report that
    /// names neither names no database. `unknown`, which the import records for a version it does not find, names nothing
    /// (``DatabaseReceiptPlaceholder``).
    static func czId(
        ntVersion: String?,
        nrVersion: String?,
        adding resolved: [String: ParameterValue]
    ) -> [String: ParameterValue] {
        guard DatabaseReceiptPlaceholder.firstNamed(among: [ntVersion, nrVersion]) != nil else {
            return notNamedBySource(tool: "CZ-ID", adding: resolved)
        }
        return resolved.merging([
            "databaseIdentityStatus": .string(DatabaseIdentityStatus.namedBySource.rawValue),
            "databaseIdentityNote": .string("The CZ-ID result states its NT and NR database versions and no checksum."),
        ]) { current, _ in current }
    }

    /// The version the values state, one string when every non-empty value agrees, the sorted distinct values as an array
    /// when they differ, and nil when none names a version.
    private static func versionValue(of versions: [String]) -> ParameterValue? {
        let distinct = Set(versions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        switch distinct.count {
        case 0:
            return nil
        case 1:
            return distinct.first.map(ParameterValue.string)
        default:
            return .array(distinct.sorted().map(ParameterValue.string))
        }
    }
}
