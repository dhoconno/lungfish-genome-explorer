// DatabaseIdentityStatus.swift - How far a recorded database is pinned, and one database entry of a Nextflow step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How far a recorded database is pinned, one vocabulary for every record (Phase 2.9 lanes B11 and B13, decision R3).
///
/// Writers keep their words until a Preview ships the tolerant reader (R3), and ``init(recordedWord:)`` is that reader.
/// Every word a released build records for the fact reads as one of the statuses, and an import adds two of its own
/// (DB-IDENTITY, Phase 3.1).
///
/// - `unpinned` is TaxTriage's and EsViritu's word, and the status's own.
/// - `unresolved-bounded-metadata` is Kraken 2's word for a database with no digest, so it reads as ``unpinned``.
/// - `provided-aggregate-digest` is Kraken 2's word when the run carries the aggregate SHA-256 that LGE's install
///   computed over the database's files, from the registry or from `--db-digest`, so it reads as ``pinned``.
package enum DatabaseIdentityStatus: String, Sendable, Equatable, CaseIterable {
    /// A SHA-256 that LGE computed over the database's files names the database, at install or in the run.
    case pinned
    /// No digest pins the database, so its path, its file sizes and its install receipt name it.
    case unpinned
    /// The run fetched the database from a live source, so the date of the fetch and the kept files that list what it
    /// fetched name it (R4).
    case liveSnapshot
    /// An imported result states the version of the database that made its calls, and no checksum. The record names
    /// that version as the source states it (DB-IDENTITY, Phase 3.1).
    case namedBySource
    /// An imported result states no database, so its record cannot name the release that made its calls
    /// (DB-IDENTITY, Phase 3.1).
    case notNamedBySource

    /// The status a record's word names, each status's own word and the two words of Kraken 2, or nil for a word no
    /// writer records. The match is exact, so a word in another case reads as nothing.
    package init?(recordedWord word: String) {
        switch word {
        case "unresolved-bounded-metadata":
            self = .unpinned
        case "provided-aggregate-digest":
            self = .pinned
        default:
            guard let own = DatabaseIdentityStatus(rawValue: word) else { return nil }
            self = own
        }
    }

    /// ``init(recordedWord:)`` as a function, for a caller that maps a sequence of words.
    package static func status(ofRecordedWord word: String) -> DatabaseIdentityStatus? {
        DatabaseIdentityStatus(recordedWord: word)
    }
}

/// The values an install receipt records for a catalog entry or version it does not know, one rule for every reader of
/// a receipt (Phase 2.9 lane B13, row 257 of the Phase 2.8 plan).
///
/// An install writes `unknown` for a database with no catalog entry (the `catalogID` option) and for one with no
/// version (the receipt's workflow version), and `unspecified` for the requested catalog version of an archive it
/// installed with no version (`MetagenomicsDatabaseInstallProvenance`). None of them names a database, so a reader skips
/// them and an empty string, and a record never files one as a catalog entry or version.
package enum DatabaseReceiptPlaceholder {
    /// The values that name nothing, the empty string included.
    package static let values: Set<String> = ["", "unknown", "unspecified"]

    /// Whether `value` names nothing.
    package static func isPlaceholder(_ value: String) -> Bool {
        values.contains(value)
    }

    /// `value` when it names something, or nil.
    package static func named(_ value: String?) -> String? {
        value.flatMap { isPlaceholder($0) ? nil : $0 }
    }

    /// The first of `candidates`, in order, that is present and names something, or nil.
    package static func firstNamed(among candidates: [String?]) -> String? {
        candidates.lazy.compactMap(named).first
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
