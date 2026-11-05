// TaxTriageDatabase+OrganismReferences.swift - Every reference of the organism of each TaxTriage row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

/// One reference sequence of the organism of a TaxTriage row, in the row's sample.
///
/// A row names one primary accession, the first reference of its organism in the sample's gcfmap. Its reads can sit
/// on the organism's other references, as Influenza A's sat on segments 5 and 2 and not on segment 4 in the NTC-P
/// batch, so Extract Reads, BLAST Verify and the alignment pane read all of them (3.2 lane TTACCESSIONS).
public struct TaxTriageOrganismReference: Sendable, Equatable {
    public let sample: String
    /// The primary accession of the row this reference belongs to.
    public let primaryAccession: String
    public let accession: String
    /// The reference's own length in the sample's BAM, nil when the build could not read it.
    public let length: Int?
    /// The mapped records on this reference in the sample's BAM (`samtools idxstats`), nil when unread.
    public let mappedReads: Int?

    public init(sample: String, primaryAccession: String, accession: String, length: Int?, mappedReads: Int?) {
        self.sample = sample
        self.primaryAccession = primaryAccession
        self.accession = accession
        self.length = length
        self.mappedReads = mappedReads
    }

    /// The key of the row a reference belongs to, its sample and its primary accession.
    public static func rowKey(sample: String, primaryAccession: String) -> String {
        "\(sample)\t\(primaryAccession)"
    }
}

extension TaxTriageDatabase {
    /// Writes `references` into the database at `url`, in their order, replacing any it held. The build calls it
    /// after its count pass and before it marks the database current.
    ///
    /// - Throws: ``TaxTriageDatabaseError/createFailed(_:)`` when the file cannot be opened or written.
    public static func storeOrganismReferences(_ references: [TaxTriageOrganismReference], at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw TaxTriageDatabaseError.createFailed("Cannot open \(url.lastPathComponent) to record its organism references")
        }
        defer { sqlite3_close(handle) }
        func run(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw TaxTriageDatabaseError.createFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
        try run("""
        CREATE TABLE IF NOT EXISTS organism_references (
            sample TEXT NOT NULL, primary_accession TEXT NOT NULL, accession TEXT NOT NULL,
            accession_length INTEGER, mapped_reads INTEGER, rank INTEGER NOT NULL,
            PRIMARY KEY (sample, primary_accession, accession)
        )
        """)
        try run("BEGIN TRANSACTION")
        do {
            try run("DELETE FROM organism_references")
            var statement: OpaquePointer?
            let sql = "INSERT OR IGNORE INTO organism_references VALUES (?, ?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw TaxTriageDatabaseError.createFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (rank, reference) in references.enumerated() {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, reference.sample, -1, transient)
                sqlite3_bind_text(statement, 2, reference.primaryAccession, -1, transient)
                sqlite3_bind_text(statement, 3, reference.accession, -1, transient)
                if let length = reference.length { sqlite3_bind_int64(statement, 4, Int64(length)) } else { sqlite3_bind_null(statement, 4) }
                if let reads = reference.mappedReads { sqlite3_bind_int64(statement, 5, Int64(reads)) } else { sqlite3_bind_null(statement, 5) }
                sqlite3_bind_int64(statement, 6, Int64(rank))
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw TaxTriageDatabaseError.createFailed(String(cString: sqlite3_errmsg(handle)))
                }
            }
            try run("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// The stored references of each of `rows`, keyed by ``TaxTriageOrganismReference/rowKey(sample:primaryAccession:)``
    /// in the order the build stored them. Empty for a database built before 3.2 lane TTACCESSIONS, whose rows each
    /// stand for their primary accession alone.
    public func fetchOrganismReferences(of rows: [TaxTriageTaxonomyRow]) throws -> [String: [TaxTriageOrganismReference]] {
        guard let db else { throw TaxTriageDatabaseError.queryFailed("Database is closed") }
        var statement: OpaquePointer?
        let sql = """
        SELECT accession, accession_length, mapped_reads FROM organism_references
        WHERE sample = ? AND primary_accession = ? ORDER BY rank
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var references: [String: [TaxTriageOrganismReference]] = [:]
        for row in rows {
            guard let primary = row.primaryAccession, !primary.isEmpty else { continue }
            let key = TaxTriageOrganismReference.rowKey(sample: row.sample, primaryAccession: primary)
            guard references[key] == nil else { continue }
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, row.sample, -1, transient)
            sqlite3_bind_text(statement, 2, primary, -1, transient)
            var found: [TaxTriageOrganismReference] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func integer(_ column: Int32) -> Int? {
                    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
                }
                found.append(TaxTriageOrganismReference(
                    sample: row.sample, primaryAccession: primary,
                    accession: String(cString: sqlite3_column_text(statement, 0)),
                    length: integer(1), mappedReads: integer(2)
                ))
            }
            if !found.isEmpty { references[key] = found }
        }
        return references
    }
}
