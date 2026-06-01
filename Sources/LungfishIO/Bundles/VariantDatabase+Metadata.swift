// VariantDatabase+Metadata.swift - Metadata queries
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Metadata Queries

    /// Returns the total number of variants in the database.
    /// Result is cached on first call for read-only databases.
    public func totalCount() -> Int {
        if let cached = cacheLock.withLock({ _cachedTotalCount }) { return cached }
        let result = computeTotalCount()
        if isReadOnly { cacheLock.withLock { _cachedTotalCount = result } }
        return result
    }

    func computeTotalCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM variants", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns all distinct variant type strings (SNP, INS, DEL, MNP, COMPLEX, REF).
    /// Result is cached on first call for read-only databases.
    public func allTypes() -> [String] {
        if let cached = cacheLock.withLock({ _cachedAllTypes }) { return cached }
        let result = computeAllTypes()
        if isReadOnly { cacheLock.withLock { _cachedAllTypes = result } }
        return result
    }

    func computeAllTypes() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT variant_type FROM variants ORDER BY variant_type", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var types: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                types.append(String(cString: cStr))
            }
        }
        return types
    }

    /// Returns all distinct chromosome names in the database.
    /// Result is cached on first call for read-only databases.
    public func allChromosomes() -> [String] {
        if let cached = cacheLock.withLock({ _cachedAllChromosomes }) { return cached }
        let result = computeAllChromosomes()
        if isReadOnly { cacheLock.withLock { _cachedAllChromosomes = result } }
        return result
    }

    func computeAllChromosomes() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT chromosome FROM variants ORDER BY chromosome", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var chroms: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                chroms.append(String(cString: cStr))
            }
        }
        return chroms
    }

    /// Returns the maximum end position per chromosome.
    /// Result is cached on first call for read-only databases.
    public func chromosomeMaxPositions() -> [String: Int] {
        if let cached = cacheLock.withLock({ _cachedChromosomeMaxPositions }) { return cached }
        let result = computeChromosomeMaxPositions()
        if isReadOnly { cacheLock.withLock { _cachedChromosomeMaxPositions = result } }
        return result
    }

    func computeChromosomeMaxPositions() -> [String: Int] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT chromosome, MAX(end_pos) FROM variants GROUP BY chromosome", -1, &stmt, nil) == SQLITE_OK else { return [:] }

        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let chrom = String(cString: cStr)
                let maxPos = Int(sqlite3_column_int64(stmt, 1))
                result[chrom] = maxPos
            }
        }
        return result
    }

    /// Returns per-chromosome variant counts.
    /// Result is cached on first call for read-only databases.
    public func chromosomeVariantCounts() -> [String: Int] {
        if let cached = cacheLock.withLock({ _cachedChromosomeCounts }) { return cached }
        let result = computeChromosomeVariantCounts()
        if isReadOnly { cacheLock.withLock { _cachedChromosomeCounts = result } }
        return result
    }

    func computeChromosomeVariantCounts() -> [String: Int] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT chromosome, COUNT(*) FROM variants GROUP BY chromosome", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                result[String(cString: cStr)] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return result
    }

    /// Returns contig lengths from VCF `##contig` header lines stored during import.
    ///
    /// These provide exact chromosome lengths for reliable alias matching when
    /// VCF chromosome names differ from the reference (e.g., "1" vs "NC_048383.1").
    /// Returns an empty dictionary if contig lengths were not stored (older databases).
    public func contigLengths() -> [String: Int64] {
        guard let db else { return [:] }
        guard let jsonString = Self.readMetadataValue(db, key: "contig_lengths") else { return [:] }
        guard let data = jsonString.data(using: String.Encoding.utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: Int64] = [:]
        for (key, value) in dict {
            if let num = value as? NSNumber {
                result[key] = num.int64Value
            }
        }
        return result
    }

}
