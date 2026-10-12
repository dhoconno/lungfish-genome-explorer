// DatabaseIdentityStatus.swift - How far a recorded database is pinned, and one database entry of a Nextflow step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How far a recorded database is pinned, one vocabulary for every record (Phase 2.9 lane B11, decision R3).
///
/// Writers keep their words until a Preview ships the tolerant reader (R3). TaxTriage and EsViritu record `unpinned`,
/// and Kraken 2 records `unresolved-bounded-metadata` for the same fact, so a reader takes that word as ``unpinned``
/// (``status(ofRecordedWord:)``).
package enum DatabaseIdentityStatus: String, Sendable, Equatable, CaseIterable {
    /// A digest LGE checked names the database.
    case pinned
    /// No digest pins the database, so its path, its file sizes and its install receipt name it.
    case unpinned
    /// The run fetched the database from a live source, so the date of the fetch and the kept files that list what it
    /// fetched name it (R4).
    case liveSnapshot

    /// The status a record's word names, each status's own word and Kraken 2's `unresolved-bounded-metadata` for
    /// ``unpinned``, or nil for a word no writer records.
    package static func status(ofRecordedWord word: String) -> DatabaseIdentityStatus? {
        word == "unresolved-bounded-metadata" ? .unpinned : DatabaseIdentityStatus(rawValue: word)
    }
}

/// One database a Nextflow step used, as its record's resolved defaults name it (Phase 2.9 lane B11, decision R4).
///
/// A database the run fetched from a live source has the status ``DatabaseIdentityStatus/liveSnapshot``, the date of
/// the fetch and the kept files that list what it fetched. TaxTriage downloads its references from NCBI during a run,
/// prunes `download/`, and keeps `combine/<sample>.combined.gcfmap.tsv` for each sample, which lists them. Lane B12
/// writes TaxTriage's entry into the executor's root record.
package struct NextflowDatabaseEntry: Sendable, Equatable {
    /// What the database is for, the key of its resolved default, such as `fetchedReferences`.
    package let role: String
    /// How far the database is pinned.
    package let status: DatabaseIdentityStatus
    /// Where the database is, nil when the run kept no copy of it.
    package let path: URL?
    /// When the run fetched the database, nil for a database it did not fetch.
    package let fetchedAt: Date?
    /// The kept files that list what the run fetched, in order.
    package let listingFiles: [URL]

    package init(
        role: String,
        status: DatabaseIdentityStatus,
        path: URL? = nil,
        fetchedAt: Date? = nil,
        listingFiles: [URL] = []
    ) {
        self.role = role
        self.status = status
        self.path = path
        self.fetchedAt = fetchedAt
        self.listingFiles = listingFiles
    }

    /// The entry as one resolved default, its role to a dictionary of `status`, `path`, `fetchedAt` and
    /// `listingFiles`, each fact left out when the entry does not know it. The fetch date is ISO 8601 in UTC with whole
    /// seconds, and the paths are files, so the writer rewrites them as it rewrites every recorded path.
    package var resolvedDefaults: [String: ParameterValue] {
        var entry: [String: ParameterValue] = ["status": .string(status.rawValue)]
        if let path {
            entry["path"] = .file(path)
        }
        if let fetchedAt {
            entry["fetchedAt"] = .string(fetchedAt.formatted(.iso8601))
        }
        if !listingFiles.isEmpty {
            entry["listingFiles"] = .array(listingFiles.map { .file($0) })
        }
        return [role: .dictionary(entry)]
    }
}
