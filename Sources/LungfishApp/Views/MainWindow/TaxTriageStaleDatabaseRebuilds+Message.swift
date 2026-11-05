// TaxTriageStaleDatabaseRebuilds+Message.swift - When a stale TaxTriage database is rebuilt and what the viewer says otherwise
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageStaleDatabaseRebuilds {
    /// True when a stale TaxTriage database should be rebuilt now. A read-only project is never written and keeps the try.
    static func shouldRebuild(readOnly: Bool, databaseURL: URL) -> Bool { !readOnly && shouldAttempt(for: databaseURL) }

    /// What the viewer says in place of rows that an older Lungfish counted.
    static func notShownMessage(resultURL: URL) -> String {
        "These TaxTriage read counts were made by an older version of Lungfish and can read 0 or too few for an organism "
            + "with several references, such as Influenza A, so they are not shown. Lungfish recounts them once when the "
            + "project is open for editing. Open the project for editing and select the result again, or run "
            + "lungfish-cli build-db taxtriage \"\(resultURL.path)\" --force."
    }

    /// What the placeholder says while the recount runs.
    static let recountSubtitle = "Recounting reads. This result was indexed by an older Lungfish, whose Reads could read 0 or too few for some organisms. Numbers you exported from it before may change."
}
