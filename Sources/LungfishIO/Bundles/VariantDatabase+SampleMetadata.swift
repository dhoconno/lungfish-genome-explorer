// VariantDatabase+SampleMetadata.swift - Sample metadata import + parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Sample Metadata Queries

    /// Returns metadata for a specific sample as a dictionary.
    public func sampleMetadata(name: String) -> [String: String] {
        guard let db else { return [:] }
        let sql = "SELECT metadata FROM samples WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        variantDBBindText(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [:] }
        guard let jsonStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    /// Returns all sample names with their metadata.
    public func allSampleMetadata() -> [(name: String, metadata: [String: String])] {
        guard let db else { return [] }
        let sql = "SELECT name, metadata FROM samples ORDER BY name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var results: [(name: String, metadata: [String: String])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            var metadata: [String: String] = [:]
            if let jsonStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                metadata = dict
            }
            results.append((name: name, metadata: metadata))
        }
        return results
    }

    /// Returns all distinct metadata field names across all samples.
    public func metadataFieldNames() -> [String] {
        let allMeta = allSampleMetadata()
        var fieldSet = Set<String>()
        for (_, metadata) in allMeta {
            fieldSet.formUnion(metadata.keys)
        }
        return fieldSet.sorted()
    }

    /// Updates metadata for a specific sample.
    public func updateSampleMetadata(name: String, metadata: [String: String]) throws {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: metadata)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

        let sql = "UPDATE samples SET metadata = ? WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare update statement")
        }
        variantDBBindText(stmt, 1, jsonStr)
        variantDBBindText(stmt, 2, name)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VariantDatabaseError.createFailed("Failed to update sample metadata for '\(name)'")
        }
    }

    /// Imports sample metadata from a TSV or CSV file.
    ///
    /// The file must have a header row. The first column is the sample name (must match
    /// VCF sample names in the database). Remaining columns become metadata key-value pairs.
    ///
    /// - Parameters:
    ///   - url: URL to the metadata file
    ///   - format: File format (.tsv or .csv)
    /// - Returns: Number of samples updated
    @discardableResult
    public func importSampleMetadata(from url: URL, format: MetadataFormat) throws -> Int {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }

        let rows: [[String]]
        switch format {
        case .tsv:
            rows = try parseTSV(url: url)
        case .csv:
            rows = try parseCSV(url: url)
        case .excel:
            throw VariantDatabaseError.createFailed("Excel import requires CoreXLSX — use importSampleMetadataFromExcel()")
        }

        guard rows.count >= 2 else { return 0 } // Need header + at least one data row
        let rawHeaders = rows[0].map(normalizeImportedCell)
        guard rawHeaders.count >= 2 else { return 0 } // Need sample name + at least one field

        // Accept common sample-name header aliases and fall back to first column.
        let sampleHeaderAliases = Set(["sample", "sample_name", "sample id", "sample_id", "name"])
        let sampleNameColumnIndex = rawHeaders.firstIndex {
            sampleHeaderAliases.contains($0.lowercased())
        } ?? 0
        let sourceHeaderAliases = Set(["source", "source_file", "source file", "vcf_source", "vcf file", "vcf_file"])
        let sourceFileColumnIndex = rawHeaders.firstIndex {
            sourceHeaderAliases.contains($0.lowercased())
        }

        let metadataColumns: [(index: Int, key: String)] = rawHeaders.enumerated().compactMap { idx, header in
            guard idx != sampleNameColumnIndex, idx != sourceFileColumnIndex else { return nil }
            let key = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return (idx, key)
        }
        guard !metadataColumns.isEmpty else { return 0 }

        let sampleSourceSQL = "SELECT name, source_file FROM samples"
        var sampleSourceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sampleSourceSQL, -1, &sampleSourceStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample-source lookup statement")
        }
        defer { sqlite3_finalize(sampleSourceStmt) }

        var pairLookup: [String: String] = [:]
        var canonicalSourceLookup: [String: String] = [:]
        var sampleToSources: [String: Set<String>] = [:]
        while sqlite3_step(sampleSourceStmt) == SQLITE_ROW {
            let sampleName = sqlite3_column_text(sampleSourceStmt, 0).map { String(cString: $0) } ?? ""
            let sourceFile = sqlite3_column_text(sampleSourceStmt, 1).map { String(cString: $0) } ?? ""
            if sampleName.isEmpty { continue }
            let normalizedSample = normalizeSampleName(sampleName)
            let normalizedSource = normalizeImportedCell(sourceFile).lowercased()
            let pairKey = "\(normalizedSample)|\(normalizedSource)"
            pairLookup[pairKey] = sampleName
            canonicalSourceLookup[pairKey] = sourceFile
            sampleToSources[normalizedSample, default: []].insert(normalizedSource)
        }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        let updateSQLByPair = "UPDATE samples SET metadata = ? WHERE name = ? AND COALESCE(source_file, '') = ?"
        let updateSQLByName = "UPDATE samples SET metadata = ? WHERE name = ?"
        var updateStmtByPair: OpaquePointer?
        var updateStmtByName: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQLByPair, -1, &updateStmtByPair, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.createFailed("Failed to prepare update statement")
        }
        guard sqlite3_prepare_v2(db, updateSQLByName, -1, &updateStmtByName, nil) == SQLITE_OK else {
            sqlite3_finalize(updateStmtByPair)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.createFailed("Failed to prepare fallback update statement")
        }
        defer {
            sqlite3_finalize(updateStmtByPair)
            sqlite3_finalize(updateStmtByName)
        }
        var updateStmt: OpaquePointer?

        var updatedCount = 0
        var skippedAmbiguousCount = 0
        for row in rows.dropFirst() {
            guard sampleNameColumnIndex < row.count else { continue }
            let importedSampleName = normalizeImportedCell(row[sampleNameColumnIndex])
            guard !importedSampleName.isEmpty else { continue }
            let normalizedSampleName = normalizeSampleName(importedSampleName)
            guard let possibleSources = sampleToSources[normalizedSampleName] else {
                variantDBLogger.info("importSampleMetadata: Skipping unknown sample '\(importedSampleName, privacy: .public)'")
                continue
            }

            var importedSourceFile: String?
            if let sourceIndex = sourceFileColumnIndex, sourceIndex < row.count {
                let value = normalizeImportedCell(row[sourceIndex])
                if !value.isEmpty {
                    importedSourceFile = value
                }
            }
            let normalizedImportedSource = importedSourceFile.map { normalizeImportedCell($0).lowercased() }

            let resolvedSampleName: String
            let resolvedSourceForUpdate: String
            var usePairUpdate = false
            if let normalizedImportedSource {
                let pairKey = "\(normalizedSampleName)|\(normalizedImportedSource)"
                guard let resolved = pairLookup[pairKey] else {
                    variantDBLogger.info(
                        "importSampleMetadata: Skipping sample '\(importedSampleName, privacy: .public)' with unmatched source '\(importedSourceFile ?? "", privacy: .public)'"
                    )
                    continue
                }
                resolvedSampleName = resolved
                resolvedSourceForUpdate = canonicalSourceLookup[pairKey] ?? (importedSourceFile ?? "")
                usePairUpdate = true
            } else if possibleSources.count == 1 {
                let onlySource = possibleSources.first ?? ""
                let pairKey = "\(normalizedSampleName)|\(onlySource)"
                guard let resolved = pairLookup[pairKey] else { continue }
                resolvedSampleName = resolved
                resolvedSourceForUpdate = canonicalSourceLookup[pairKey] ?? onlySource
                usePairUpdate = sourceFileColumnIndex != nil
            } else {
                skippedAmbiguousCount += 1
                variantDBLogger.info(
                    "importSampleMetadata: Skipping ambiguous sample '\(importedSampleName, privacy: .public)' (provide source_file column)"
                )
                continue
            }

            // Build metadata dictionary from remaining columns
            var metadata: [String: String] = [:]
            for (index, key) in metadataColumns where index < row.count {
                let value = normalizeImportedCell(row[index])
                if !value.isEmpty {
                    metadata[key] = value
                }
            }

            // Merge with existing metadata
            var existing = sampleMetadata(name: resolvedSampleName)
            existing.merge(metadata) { _, new in new }

            let jsonData = try JSONSerialization.data(withJSONObject: existing)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

            updateStmt = usePairUpdate ? updateStmtByPair : updateStmtByName
            sqlite3_reset(updateStmt)
            variantDBBindText(updateStmt, 1, jsonStr)
            variantDBBindText(updateStmt, 2, resolvedSampleName)
            if usePairUpdate {
                variantDBBindText(updateStmt, 3, resolvedSourceForUpdate)
            }

            if sqlite3_step(updateStmt) == SQLITE_DONE {
                updatedCount += 1
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if skippedAmbiguousCount > 0 {
            variantDBLogger.info("importSampleMetadata: Skipped \(skippedAmbiguousCount) ambiguous rows missing source_file")
        }
        variantDBLogger.info("importSampleMetadata: Updated \(updatedCount) samples from \(url.lastPathComponent)")
        return updatedCount
    }

    // MARK: - TSV/CSV Parsing

    func parseTSV(url: URL) throws -> [[String]] {
        let content = try readTextFileForMetadataImport(url: url)
        return parseDelimitedRows(content, delimiter: "\t")
    }

    func parseCSV(url: URL) throws -> [[String]] {
        let content = try readTextFileForMetadataImport(url: url)
        return parseDelimitedRows(content, delimiter: ",")
    }

    /// Parses delimited text (TSV/CSV), honoring quoted fields for the active delimiter.
    func parseDelimitedRows(_ content: String, delimiter: Character) -> [[String]] {
        content
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { parseDelimitedLine(String($0), delimiter: delimiter) }
    }

    /// Parses a single delimited line, handling quoted fields with embedded delimiters.
    func parseDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var prevWasQuote = false
        for char in line {
            if inQuotes {
                if char == "\"" {
                    if prevWasQuote {
                        current.append("\"")
                        prevWasQuote = false
                    } else {
                        prevWasQuote = true
                    }
                } else if char == delimiter && prevWasQuote {
                    inQuotes = false
                    prevWasQuote = false
                    fields.append(current)
                    current = ""
                } else {
                    if prevWasQuote {
                        inQuotes = false
                        prevWasQuote = false
                    }
                    current.append(char)
                }
            } else {
                if char == "\"" && current.isEmpty {
                    inQuotes = true
                    prevWasQuote = false
                } else if char == delimiter {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
            }
        }
        // Handle final field
        if prevWasQuote { inQuotes = false }
        fields.append(current)
        return fields
    }

    func readTextFileForMetadataImport(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        throw VariantDatabaseError.createFailed("Unable to decode metadata file '\(url.lastPathComponent)' as UTF-8/UTF-16 text")
    }

    /// Normalizes imported cells by trimming whitespace/newlines and stripping UTF BOM.
    func normalizeImportedCell(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    /// Canonical sample-name key used for robust sample matching on import.
    func normalizeSampleName(_ value: String) -> String {
        normalizeImportedCell(value).lowercased()
    }
}
