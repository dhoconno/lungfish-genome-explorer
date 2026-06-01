// VariantDatabase+Genotypes.swift - Row reader, genotype queries, mutations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Variant Row Reader

    /// Reads variant rows from a prepared statement.
    ///
    /// Expected column order: id, chromosome, position, end_pos, variant_id, ref, alt,
    /// variant_type, quality, filter, info, sample_count
    func readVariantRows(stmt: OpaquePointer) -> [VariantDatabaseRecord] {
        var results: [VariantDatabaseRecord] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let chrom = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let pos = Int(sqlite3_column_int64(stmt, 2))
            let endPos = Int(sqlite3_column_int64(stmt, 3))
            let vid = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let ref = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let alt = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let vtype = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "SNP"
            let quality: Double? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
            let filter = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let info = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let sampleCount = Int(sqlite3_column_int64(stmt, 11))

            results.append(VariantDatabaseRecord(
                id: rowId,
                chromosome: chrom, position: pos, end: endPos, variantID: vid,
                ref: ref, alt: alt, variantType: vtype,
                quality: quality, filter: filter, info: info,
                sampleCount: sampleCount
            ))
        }
        return results
    }

    // MARK: - Genotype Queries

    /// Returns all sample names in the database.
    public func sampleNames() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM samples ORDER BY name", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: cStr))
            }
        }
        return names
    }

    /// Returns sample names that have at least one non-homRef genotype on a chromosome.
    ///
    /// Useful for multi-VCF imports where each source contributes variants to only a
    /// subset of chromosomes/contigs.
    public func sampleNames(chromosome: String) -> [String] {
        guard let db else { return [] }
        let sql = """
            SELECT DISTINCT g.sample_name
            FROM genotypes g
            INNER JOIN variants v ON v.id = g.variant_id
            WHERE v.chromosome = ?
            ORDER BY g.sample_name
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        variantDBBindText(stmt, 1, chromosome)

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: cStr))
            }
        }
        return names
    }

    /// Returns the number of samples in the database.
    public func sampleCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns genotype records for a specific variant (by row ID).
    public func genotypes(forVariantId variantRowId: Int64) -> [GenotypeRecord] {
        guard let db else { return [] }
        let sql = "SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields FROM genotypes WHERE variant_id = ? ORDER BY sample_name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, variantRowId)
        return readGenotypeRows(stmt: stmt!)
    }

    /// Returns genotype records for many variants in one query batch.
    ///
    /// This avoids N+1 round trips when rendering genotype-heavy table views.
    public func genotypes(forVariantIds variantRowIds: [Int64]) -> [Int64: [GenotypeRecord]] {
        guard let db else { return [:] }
        let uniqueIds = Array(Set(variantRowIds))
        guard !uniqueIds.isEmpty else { return [:] }

        var grouped: [Int64: [GenotypeRecord]] = [:]
        let chunkSize = 500
        for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
            let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields
                FROM genotypes
                WHERE variant_id IN (\(placeholders))
                ORDER BY variant_id, sample_name
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for (idx, id) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(idx + 1), id)
            }
            let rows = readGenotypeRows(stmt: stmt!)
            for row in rows {
                grouped[row.variantRowId, default: []].append(row)
            }
        }
        return grouped
    }

    /// Returns genotype records for a specific sample in a genomic region.
    ///
    /// Joins genotypes with variants to filter by region.
    public func genotypes(forSample sampleName: String, chromosome: String, start: Int, end: Int) -> [GenotypeRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT g.variant_id, g.sample_name, g.genotype, g.allele1, g.allele2,
                   g.is_phased, g.depth, g.genotype_quality, g.allele_depths, g.raw_fields
            FROM genotypes g
            JOIN variants v ON g.variant_id = v.id
            WHERE g.sample_name = ? AND v.chromosome = ? AND v.position < ? AND v.end_pos > ?
            ORDER BY v.position
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        variantDBBindText(stmt, 1, sampleName)
        variantDBBindText(stmt, 2, chromosome)
        sqlite3_bind_int64(stmt, 3, Int64(end))
        sqlite3_bind_int64(stmt, 4, Int64(start))
        return readGenotypeRows(stmt: stmt!)
    }

    /// Returns all genotypes for all samples in a genomic region, grouped by variant position.
    ///
    /// This is the primary query for genotype rendering — returns variant positions with
    /// all sample genotypes for that region. Uses a single JOIN query to avoid N+1 round-trips.
    public func genotypesInRegion(chromosome: String, start: Int, end: Int, limit: Int = 10_000) -> [(variant: VariantDatabaseRecord, genotypes: [GenotypeRecord])] {
        guard let db else { return [] }

        // Step 1: fetch a bounded list of variant rows in-region.
        let variantSQL = """
            SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            FROM variants
            WHERE chromosome = ? AND position < ? AND end_pos > ?
            ORDER BY position, id
            LIMIT ?
            """
        var variantStmt: OpaquePointer?
        defer { sqlite3_finalize(variantStmt) }
        guard sqlite3_prepare_v2(db, variantSQL, -1, &variantStmt, nil) == SQLITE_OK else {
            variantDBLogger.error("genotypesInRegion: Failed to prepare variant query")
            return []
        }
        variantDBBindText(variantStmt, 1, chromosome)
        sqlite3_bind_int64(variantStmt, 2, Int64(end))
        sqlite3_bind_int64(variantStmt, 3, Int64(start))
        sqlite3_bind_int64(variantStmt, 4, Int64(limit))
        let variants = readVariantRows(stmt: variantStmt!)
        guard !variants.isEmpty else { return [] }

        // Step 2: fetch all genotypes for just those variant IDs.
        // Chunk to avoid exceeding SQLITE_MAX_VARIABLE_NUMBER (default 999).
        let variantIDs = variants.compactMap(\.id)
        guard !variantIDs.isEmpty else {
            return variants.map { ($0, []) }
        }
        let genotypeMap = genotypes(forVariantIds: variantIDs)
        return variants.map { variant in
            let rows = variant.id.flatMap { genotypeMap[$0] } ?? []
            return (variant: variant, genotypes: rows)
        }
    }

    /// Writes database records as a minimal VCF with selected sample genotype columns.
    public func writeVCF(
        records: [VariantDatabaseRecord],
        sampleNames requestedSampleNames: [String],
        to outputURL: URL
    ) throws {
        let availableSamples = sampleNames()
        let selectedSamples = requestedSampleNames.isEmpty
            ? availableSamples
            : requestedSampleNames.filter { availableSamples.contains($0) }
        let ids = records.compactMap(\.id)
        let genotypeMap = genotypes(forVariantIds: ids)

        var lines: [String] = [
            "##fileformat=VCFv4.2",
            "##source=lungfish",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Read depth\">",
            "##FORMAT=<ID=GQ,Number=1,Type=Integer,Description=\"Genotype quality\">",
            "##FORMAT=<ID=AD,Number=R,Type=Integer,Description=\"Allele depths\">",
        ]

        var header = ["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO"]
        if !selectedSamples.isEmpty {
            header.append("FORMAT")
            header.append(contentsOf: selectedSamples)
        }
        lines.append(header.joined(separator: "\t"))

        for record in records {
            let rowId = record.id ?? -1
            let genotypes = Dictionary(uniqueKeysWithValues: (genotypeMap[rowId] ?? []).map { ($0.sampleName, $0) })
            var fields = [
                record.chromosome,
                String(record.position + 1),
                record.variantID,
                record.ref,
                record.alt,
                record.quality.map { String(format: "%.2f", $0) } ?? ".",
                record.filter ?? ".",
                record.info ?? ".",
            ]
            if !selectedSamples.isEmpty {
                fields.append("GT:DP:GQ:AD")
                for sampleName in selectedSamples {
                    fields.append(vcfSamplePayload(from: genotypes[sampleName]))
                }
            }
            lines.append(fields.joined(separator: "\t"))
        }

        try lines.joined(separator: "\n").appending("\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    func vcfSamplePayload(from genotype: GenotypeRecord?) -> String {
        guard let genotype else { return ".:.:.:." }
        return [
            genotype.genotype ?? ".",
            genotype.depth.map(String.init) ?? ".",
            genotype.genotypeQuality.map(String.init) ?? ".",
            genotype.alleleDepths ?? ".",
        ].joined(separator: ":")
    }

    /// Reads genotype rows from a prepared statement.
    func readGenotypeRows(stmt: OpaquePointer) -> [GenotypeRecord] {
        var results: [GenotypeRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let variantId = sqlite3_column_int64(stmt, 0)
            let sampleName = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let genotype = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let allele1 = Int(sqlite3_column_int(stmt, 3))
            let allele2 = Int(sqlite3_column_int(stmt, 4))
            let isPhased = sqlite3_column_int(stmt, 5) != 0
            let depth: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
            let gq: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7))
            let ad = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let raw = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

            results.append(GenotypeRecord(
                variantRowId: variantId,
                sampleName: sampleName,
                genotype: genotype,
                allele1: allele1,
                allele2: allele2,
                isPhased: isPhased,
                depth: depth,
                genotypeQuality: gq,
                alleleDepths: ad,
                rawFields: raw
            ))
        }
        return results
    }

    // MARK: - Mutation Methods (Read-Write)

    /// Renames chromosome names in the variants table using the given mapping.
    ///
    /// Used during VCF import to normalize chromosome names (e.g., `MN908947.3` → `MN908947`).
    /// The database must be opened in read-write mode.
    ///
    /// - Parameter mapping: Dictionary mapping old chromosome names to new names
    /// - Throws: If the database is read-only or the update fails
    public func renameChromosomes(_ mapping: [String: String]) throws {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        guard !mapping.isEmpty else { return }

        let sql = "UPDATE variants SET chromosome = ? WHERE chromosome = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare chromosome rename statement")
        }

        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &errMsg)

        for (oldName, newName) in mapping {
            sqlite3_reset(stmt)
            variantDBBindText(stmt, 1, newName)
            variantDBBindText(stmt, 2, oldName)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw VariantDatabaseError.createFailed("Failed to rename chromosome '\(oldName)' → '\(newName)'")
            }
            let changes = sqlite3_changes(db)
            if changes > 0 {
                variantDBLogger.info("renameChromosomes: '\(oldName)' → '\(newName)' (\(changes) variants)")
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Inserts or replaces metadata values in the `db_metadata` table.
    ///
    /// - Parameter values: Metadata key-value pairs to upsert.
    /// - Throws: If the database is read-only or a write fails.
    public func setMetadataValues(_ values: [String: String]) throws {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        guard !values.isEmpty else { return }

        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &errMsg)
        if let errMsg {
            let message = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw VariantDatabaseError.createFailed("Failed to begin metadata transaction: \(message)")
        }

        do {
            for (key, value) in values {
                guard Self.insertMetadataRow(db, key: key, value: value, replace: true) else {
                    throw VariantDatabaseError.createFailed("Failed to insert metadata value for \(key)")
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Deletes variants by their row IDs, including associated genotype records.
    ///
    /// - Parameter ids: Array of variant row IDs to delete
    /// - Throws: If the database is read-only or the delete fails
    public func deleteVariants(ids: [Int64]) throws -> Int {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        guard !ids.isEmpty else { return 0 }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        do {
            try executeSQL("BEGIN TRANSACTION")

            // Child rows must be deleted BEFORE variants because PRAGMA foreign_keys = ON
            // is active at runtime and the schema declares REFERENCES variants(id) without
            // ON DELETE CASCADE. Deleting a variant first would trigger SQLITE_CONSTRAINT.
            let deleteInfoSQL = "DELETE FROM variant_info WHERE variant_id IN (\(placeholders))"
            var infoStmt: OpaquePointer?
            defer { sqlite3_finalize(infoStmt) }
            guard sqlite3_prepare_v2(db, deleteInfoSQL, -1, &infoStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare info delete statement")
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(infoStmt, Int32(i + 1), id)
            }
            guard sqlite3_step(infoStmt) == SQLITE_DONE else {
                throw VariantDatabaseError.createFailed("Failed to delete info for selected variants")
            }

            let deleteGenotypesSQL = "DELETE FROM genotypes WHERE variant_id IN (\(placeholders))"
            var gtStmt: OpaquePointer?
            defer { sqlite3_finalize(gtStmt) }
            guard sqlite3_prepare_v2(db, deleteGenotypesSQL, -1, &gtStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare genotype delete statement")
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(gtStmt, Int32(i + 1), id)
            }
            guard sqlite3_step(gtStmt) == SQLITE_DONE else {
                throw VariantDatabaseError.createFailed("Failed to delete genotypes for selected variants")
            }

            let deleteVariantsSQL = "DELETE FROM variants WHERE id IN (\(placeholders))"
            var varStmt: OpaquePointer?
            defer { sqlite3_finalize(varStmt) }
            guard sqlite3_prepare_v2(db, deleteVariantsSQL, -1, &varStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare variant delete statement")
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(varStmt, Int32(i + 1), id)
            }
            guard sqlite3_step(varStmt) == SQLITE_DONE else {
                throw VariantDatabaseError.createFailed("Failed to delete variants")
            }

            let deleted = Int(sqlite3_changes(db))
            try executeSQL("COMMIT")
            variantDBLogger.info("deleteVariants: Deleted \(deleted) variants")
            return deleted
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Deletes all variants and associated genotypes from the database.
    ///
    /// - Throws: If the database is read-only or the delete fails
    public func deleteAllVariants() throws -> Int {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }

        do {
            try executeSQL("BEGIN TRANSACTION")
            try executeSQL("DELETE FROM variant_info")
            try executeSQL("DELETE FROM genotypes")
            try executeSQL("DELETE FROM variants")
            let deleted = Int(sqlite3_changes(db))
            try executeSQL("COMMIT")
            variantDBLogger.info("deleteAllVariants: Deleted \(deleted) variants")
            return deleted
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Returns the total number of variants in the database.
    /// Delegates to `totalCount()` which caches the result for read-only databases.
    public func totalVariantCount() -> Int {
        totalCount()
    }

}
