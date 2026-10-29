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
}
